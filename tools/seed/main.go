// seed — load the Kafka-on-GCP rig with data that looks like usage, and verify it.
//
// Runs ON THE DRIVER VM (inside the VPC, next to the brokers) so that seeding 5 GB
// takes a minute, not an afternoon over the operator's uplink. Built for linux/amd64
// by seed.sh and copied over.
//
// What "looks like usage" means here, concretely — each of these is something a
// migration tool has to carry across, so each must be present to be tested:
//
//   - ten topics with domain names (orders, payments, ...), six partitions, three
//     replicas, min.insync.replicas=2 set per topic, not only broker-wide;
//   - keyed records: the key space is deliberately much smaller than the record
//     count, so keys repeat and partition affinity is real (the same key always lands
//     on the same partition — a migration that loses this reorders a customer's events);
//   - record headers (source, schema-version, trace-id) and a JSON body with a
//     monotonically increasing per-topic sequence, padded to the requested size;
//   - three consumer groups with committed offsets at different depths — one caught
//     up, one halfway, one just started — so "where was each consumer?" has three
//     different answers to migrate. The groups have no live members, which is exactly
//     the state a consumer fleet is in when it has been stopped for a cutover.
//
// Modes:
//
//	seed    create topics, produce, commit group offsets, then verify (default)
//	verify  only verify — assert broker count, topics, partitions, replication, the
//	        total record count and every group's committed offsets, and print a summary
//
// Exit status is non-zero on ANY produce error, ANY partition mismatch, or a record
// count that is not exactly what was asked for. A seeder that reports success on a
// short load has produced a fixture that cannot tell a correct migration from a lossy one.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kgo"
)

var topicNames = []string{
	"orders", "payments", "inventory", "shipments", "users",
	"clicks", "notifications", "audit", "sensors", "invoices",
}

type group struct {
	name     string
	fraction float64 // committed = floor(endOffset * fraction) per partition
}

func main() {
	brokers := flag.String("brokers", "", "comma-separated bootstrap brokers (required)")
	mode := flag.String("mode", "seed", "seed | verify")
	topics := flag.Int("topics", 10, "topic count (first N of the built-in domain names)")
	partitions := flag.Int("partitions", 6, "partitions per topic")
	rf := flag.Int("rf", 3, "replication factor")
	minISR := flag.Int("min-isr", 2, "min.insync.replicas per topic")
	records := flag.Int64("records", 5_000_000, "TOTAL records across all topics (seed) / expected total (verify; 0 = don't check)")
	size := flag.Int("size", 1024, "record value size in bytes")
	keys := flag.Int("keys", 5000, "distinct keys per topic (smaller than records => keys repeat => partition affinity)")
	groupsSpec := flag.String("groups", "analytics:1.0,billing:0.5,archiver:0.1", "consumer groups as name:fraction-of-log-committed")
	recreate := flag.Bool("recreate", false, "seed: delete existing rig topics first")
	timeout := flag.Duration("timeout", 30*time.Minute, "overall deadline")
	flag.Parse()

	if *brokers == "" {
		fatalf("-brokers is required")
	}
	if *topics < 1 || *topics > len(topicNames) {
		fatalf("-topics must be 1..%d", len(topicNames))
	}
	names := topicNames[:*topics]
	groups, err := parseGroups(*groupsSpec)
	if err != nil {
		fatalf("%v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	cl, err := kgo.NewClient(
		kgo.SeedBrokers(strings.Split(*brokers, ",")...),
		kgo.MetadataMinAge(250*time.Millisecond),
	)
	if err != nil {
		fatalf("client: %v", err)
	}
	defer cl.Close()
	adm := kadm.NewClient(cl)

	switch *mode {
	case "seed":
		perTopic := *records / int64(*topics)
		total := perTopic * int64(*topics)
		if total != *records {
			fmt.Printf("note: %d records does not divide by %d topics; seeding %d (%d per topic)\n", *records, *topics, total, perTopic)
		}
		createTopics(ctx, adm, names, int32(*partitions), int16(*rf), *minISR, *recreate)
		produce(ctx, *brokers, names, perTopic, *size, *keys)
		commitGroups(ctx, adm, names, groups)
		verify(ctx, adm, names, *partitions, *rf, total, groups)
	case "verify":
		verify(ctx, adm, names, *partitions, *rf, *records, groups)
	default:
		fatalf("unknown -mode %q", *mode)
	}
}

func parseGroups(spec string) ([]group, error) {
	var out []group
	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		name, frac, ok := strings.Cut(part, ":")
		if !ok {
			return nil, fmt.Errorf("group %q: want name:fraction", part)
		}
		f, err := strconv.ParseFloat(frac, 64)
		if err != nil || f < 0 || f > 1 {
			return nil, fmt.Errorf("group %q: fraction must be 0..1", part)
		}
		out = append(out, group{name: name, fraction: f})
	}
	if len(out) == 0 {
		return nil, errors.New("no consumer groups given")
	}
	return out, nil
}

func createTopics(ctx context.Context, adm *kadm.Client, names []string, parts int32, rf int16, minISR int, recreate bool) {
	existing, err := adm.ListTopics(ctx, names...)
	if err != nil {
		fatalf("list topics: %v", err)
	}
	var present []string
	for _, n := range names {
		if existing.Has(n) {
			present = append(present, n)
		}
	}
	if len(present) > 0 {
		if !recreate {
			fatalf("topics already exist (%s). The rig is already seeded: run -mode verify, or pass -recreate to wipe and reseed.", strings.Join(present, ","))
		}
		fmt.Printf("== deleting %d existing topics (-recreate) ==\n", len(present))
		if _, derr := adm.DeleteTopics(ctx, present...); derr != nil {
			fatalf("delete topics: %v", derr)
		}
		// Deletion is asynchronous; a create racing it fails with TOPIC_ALREADY_EXISTS.
		for {
			still, lerr := adm.ListTopics(ctx, present...)
			if lerr != nil {
				fatalf("list topics: %v", lerr)
			}
			gone := true
			for _, n := range present {
				if still.Has(n) {
					gone = false
				}
			}
			if gone {
				break
			}
			select {
			case <-ctx.Done():
				fatalf("timed out waiting for topic deletion")
			case <-time.After(500 * time.Millisecond):
			}
		}
	}
	fmt.Printf("== creating %d topics: %d partitions, rf=%d, min.insync.replicas=%d ==\n", len(names), parts, rf, minISR)
	isr := strconv.Itoa(minISR)
	resps, err := adm.CreateTopics(ctx, parts, rf, map[string]*string{"min.insync.replicas": &isr}, names...)
	if err != nil {
		fatalf("create topics: %v", err)
	}
	for _, r := range resps.Sorted() {
		if r.Err != nil {
			fatalf("create topic %s: %v", r.Topic, r.Err)
		}
	}
	// Leaders take a moment to be elected; a produce against a leaderless partition
	// retries, but the verify step's replica assertions would race. Wait for metadata.
	for {
		td, err := adm.ListTopics(ctx, names...)
		if err != nil {
			fatalf("list topics: %v", err)
		}
		ready := true
		for _, n := range names {
			t, ok := td[n]
			if !ok || len(t.Partitions) != int(parts) {
				ready = false
				break
			}
			for _, p := range t.Partitions {
				if p.Leader < 0 || len(p.Replicas) != int(rf) {
					ready = false
				}
			}
		}
		if ready {
			return
		}
		select {
		case <-ctx.Done():
			fatalf("timed out waiting for topic leaders")
		case <-time.After(500 * time.Millisecond):
		}
	}
}

type payload struct {
	Topic string `json:"topic"`
	Seq   int64  `json:"seq"`
	Key   string `json:"entity"`
	TS    int64  `json:"ts_ms"`
	Pad   string `json:"pad"`
}

func produce(ctx context.Context, brokers string, names []string, perTopic int64, size, keys int) {
	fmt.Printf("== producing %d records per topic x %d topics = %d records of %d bytes (%d keys/topic) ==\n",
		perTopic, len(names), perTopic*int64(len(names)), size, keys)
	var (
		acked  atomic.Int64
		failed atomic.Int64
		first  atomic.Pointer[error]
		wg     sync.WaitGroup
	)
	start := time.Now()
	done := make(chan struct{})
	go func() {
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				a := acked.Load()
				el := time.Since(start).Seconds()
				fmt.Printf("   %d acked  (%.0f rec/s, %.1f MB/s)  errors=%d\n", a, float64(a)/el, float64(a)*float64(size)/el/1e6, failed.Load())
			}
		}
	}()
	for _, topic := range names {
		wg.Add(1)
		go func(topic string) {
			defer wg.Done()
			// One producer per topic: idempotent, acks=all (kgo defaults), no compression so
			// the bytes on disk are the bytes asked for. Linger a little so batches fill.
			cl, err := kgo.NewClient(
				kgo.SeedBrokers(strings.Split(brokers, ",")...),
				kgo.DefaultProduceTopic(topic),
				kgo.ProducerLinger(5*time.Millisecond),
				kgo.ProducerBatchMaxBytes(1<<20),
				kgo.MaxBufferedRecords(50_000),
				kgo.RecordRetries(10),
			)
			if err != nil {
				e := fmt.Errorf("%s: client: %w", topic, err)
				first.CompareAndSwap(nil, &e)
				failed.Add(perTopic)
				return
			}
			defer cl.Close()
			for seq := int64(0); seq < perTopic; seq++ {
				key := fmt.Sprintf("%s-%06d", topic, seq%int64(keys))
				body, _ := json.Marshal(payload{Topic: topic, Seq: seq, Key: key, TS: time.Now().UnixMilli()})
				if len(body) < size {
					// Pad inside the JSON so the value is both valid JSON and exactly `size` bytes.
					pad := strings.Repeat("x", size-len(body))
					body, _ = json.Marshal(payload{Topic: topic, Seq: seq, Key: key, TS: time.Now().UnixMilli(), Pad: pad})
					// json escaping is stable for 'x', so this lands on exactly size bytes.
				}
				r := &kgo.Record{
					Key:   []byte(key),
					Value: body,
					Headers: []kgo.RecordHeader{
						{Key: "source", Value: []byte("kafka-gcp-seed")},
						{Key: "schema-version", Value: []byte("1")},
						{Key: "trace-id", Value: []byte(fmt.Sprintf("%s-%d", topic, seq))},
					},
				}
				cl.Produce(ctx, r, func(_ *kgo.Record, err error) {
					if err != nil {
						failed.Add(1)
						e := fmt.Errorf("%s: produce: %w", topic, err)
						first.CompareAndSwap(nil, &e)
						return
					}
					acked.Add(1)
				})
				if failed.Load() > 0 {
					break
				}
			}
			if err := cl.Flush(ctx); err != nil {
				e := fmt.Errorf("%s: flush: %w", topic, err)
				first.CompareAndSwap(nil, &e)
			}
		}(topic)
	}
	wg.Wait()
	close(done)
	el := time.Since(start)
	want := perTopic * int64(len(names))
	fmt.Printf("   produced %d/%d in %s (%.0f rec/s, %.1f MB/s), errors=%d\n",
		acked.Load(), want, el.Round(time.Second), float64(acked.Load())/el.Seconds(), float64(acked.Load())*float64(size)/el.Seconds()/1e6, failed.Load())
	if p := first.Load(); p != nil {
		fatalf("produce FAILED: %v (first error; %d failures total)", *p, failed.Load())
	}
	if acked.Load() != want {
		fatalf("produce FAILED: acked %d, wanted %d", acked.Load(), want)
	}
}

func commitGroups(ctx context.Context, adm *kadm.Client, names []string, groups []group) {
	ends, err := adm.ListEndOffsets(ctx, names...)
	if err != nil {
		fatalf("list end offsets: %v", err)
	}
	if err := ends.Error(); err != nil {
		fatalf("list end offsets: %v", err)
	}
	for _, g := range groups {
		var os kadm.Offsets
		ends.Each(func(o kadm.ListedOffset) {
			os.AddOffset(o.Topic, o.Partition, int64(float64(o.Offset)*g.fraction), -1)
		})
		resp, err := adm.CommitOffsets(ctx, g.name, os)
		if err != nil {
			fatalf("commit offsets for group %s: %v", g.name, err)
		}
		if err := resp.Error(); err != nil {
			fatalf("commit offsets for group %s: %v", g.name, err)
		}
		fmt.Printf("== group %-10s committed at %3.0f%% of every partition ==\n", g.name, g.fraction*100)
	}
}

func verify(ctx context.Context, adm *kadm.Client, names []string, parts, rf int, wantTotal int64, groups []group) {
	fmt.Println("== verify ==")
	bad := 0
	fail := func(format string, a ...any) { bad++; fmt.Printf("   ⛔ "+format+"\n", a...) }

	brokers, err := adm.ListBrokers(ctx)
	if err != nil {
		fatalf("list brokers: %v", err)
	}
	if len(brokers) != rf {
		fail("brokers: %d online, want %d", len(brokers), rf)
	} else {
		var ids []string
		for _, b := range brokers {
			ids = append(ids, fmt.Sprintf("%d@%s:%d", b.NodeID, b.Host, b.Port))
		}
		fmt.Printf("   ✅ brokers online: %s\n", strings.Join(ids, " "))
	}

	td, err := adm.ListTopics(ctx, names...)
	if err != nil {
		fatalf("list topics: %v", err)
	}
	for _, n := range names {
		t, ok := td[n]
		if !ok || t.Err != nil {
			fail("topic %s: missing (%v)", n, errOf(ok, t.Err))
			continue
		}
		if len(t.Partitions) != parts {
			fail("topic %s: %d partitions, want %d", n, len(t.Partitions), parts)
		}
		for _, p := range t.Partitions.Sorted() {
			if len(p.Replicas) != rf {
				fail("topic %s/%d: %d replicas, want %d", n, p.Partition, len(p.Replicas), rf)
			}
			if len(p.ISR) != rf {
				fail("topic %s/%d: ISR %v short of replicas %v (under-replicated)", n, p.Partition, p.ISR, p.Replicas)
			}
			if p.Leader < 0 {
				fail("topic %s/%d: no leader", n, p.Partition)
			}
		}
	}

	ends, err := adm.ListEndOffsets(ctx, names...)
	if err != nil {
		fatalf("list end offsets: %v", err)
	}
	if err := ends.Error(); err != nil {
		fatalf("list end offsets: %v", err)
	}
	perTopic := map[string]int64{}
	var total int64
	ends.Each(func(o kadm.ListedOffset) { perTopic[o.Topic] += o.Offset; total += o.Offset })
	fmt.Println("   topic          records")
	for _, n := range names {
		fmt.Printf("   %-14s %9d\n", n, perTopic[n])
	}
	if wantTotal > 0 && total != wantTotal {
		fail("total records %d, want %d", total, wantTotal)
	} else {
		fmt.Printf("   ✅ total records: %d\n", total)
	}

	fmt.Println("   group        committed     lag   (summed over all partitions)")
	for _, g := range groups {
		fo, err := adm.FetchOffsets(ctx, g.name)
		if err != nil {
			fail("group %s: fetch offsets: %v", g.name, err)
			continue
		}
		if err := fo.Error(); err != nil {
			fail("group %s: fetch offsets: %v", g.name, err)
			continue
		}
		var committed, lag int64
		var n int
		fo.Each(func(o kadm.OffsetResponse) {
			if o.At < 0 {
				return
			}
			n++
			committed += o.At
			if end, ok := ends.Lookup(o.Topic, o.Partition); ok {
				lag += end.Offset - o.At
			}
		})
		wantParts := len(names) * parts
		if n != wantParts {
			fail("group %s: committed offsets on %d partitions, want %d", g.name, n, wantParts)
			continue
		}
		fmt.Printf("   %-12s %9d %9d\n", g.name, committed, lag)
	}

	if bad > 0 {
		fatalf("VERIFY FAILED: %d problems", bad)
	}
	sort.Strings(names)
	fmt.Printf("✅ VERIFY PASSED: %d brokers, %d topics x %d partitions x rf=%d, %d records, %d consumer groups\n",
		len(brokers), len(names), parts, rf, total, len(groups))
}

func errOf(ok bool, err error) error {
	if !ok {
		return errors.New("not found")
	}
	return err
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", a...)
	os.Exit(1)
}
