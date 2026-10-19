/**
 * Fixed-memory latency histogram for the capacity driver.
 *
 * 1 ms buckets up to `maxMs` (default 120 s), one overflow bucket. Memory is
 * constant (≈480 KB) no matter how many samples a 2500-user soak records, and
 * two histograms from different shard processes merge by element-wise add —
 * percentiles over the merged counts are exact at 1 ms resolution.
 */
export class LatencyHistogram {
  readonly counts: Uint32Array;
  readonly maxMs: number;
  total = 0;
  sum = 0;
  max = 0;

  constructor(maxMs = 120_000) {
    this.maxMs = maxMs;
    this.counts = new Uint32Array(maxMs + 2);
  }

  record(ms: number): void {
    if (!Number.isFinite(ms)) return;
    const v = ms < 0 ? 0 : ms;
    const bucket = v > this.maxMs ? this.maxMs + 1 : Math.floor(v);
    this.counts[bucket] = (this.counts[bucket] ?? 0) + 1;
    this.total += 1;
    this.sum += v;
    if (v > this.max) this.max = v;
  }

  /** Percentile in ms (bucket upper edge); 0 when empty. */
  percentile(p: number): number {
    if (this.total === 0) return 0;
    const rank = Math.max(1, Math.ceil((p / 100) * this.total));
    let seen = 0;
    for (let i = 0; i < this.counts.length; i += 1) {
      seen += this.counts[i]!;
      if (seen >= rank) return i > this.maxMs ? this.max : i + 1;
    }
    return this.max;
  }

  mean(): number {
    return this.total === 0 ? 0 : this.sum / this.total;
  }

  merge(other: LatencyHistogram | SerializedHistogram): void {
    const counts = other instanceof LatencyHistogram ? other.counts : decodeCounts(other);
    if (counts.length !== this.counts.length) {
      throw new Error("LatencyHistogram.merge: bucket layout mismatch");
    }
    for (let i = 0; i < counts.length; i += 1) this.counts[i]! += counts[i]!;
    this.total += other.total;
    this.sum += other.sum;
    this.max = Math.max(this.max, other.max);
  }

  serialize(): SerializedHistogram {
    // Sparse encoding: [bucket, count, bucket, count, …] — a few KB on the
    // child→parent pipe instead of 120k zeros.
    const sparse: number[] = [];
    for (let i = 0; i < this.counts.length; i += 1) {
      const c = this.counts[i]!;
      if (c !== 0) sparse.push(i, c);
    }
    return { maxMs: this.maxMs, sparse, total: this.total, sum: this.sum, max: this.max };
  }

  static from(s: SerializedHistogram): LatencyHistogram {
    const h = new LatencyHistogram(s.maxMs);
    h.merge(s);
    return h;
  }

  summary(): { samples: number; p50: number; p95: number; p99: number; max: number; mean: number } {
    return {
      samples: this.total,
      p50: this.percentile(50),
      p95: this.percentile(95),
      p99: this.percentile(99),
      max: Math.round(this.max),
      mean: Math.round(this.mean() * 10) / 10,
    };
  }
}

export interface SerializedHistogram {
  maxMs: number;
  sparse: number[];
  total: number;
  sum: number;
  max: number;
}

function decodeCounts(s: SerializedHistogram): Uint32Array {
  const counts = new Uint32Array(s.maxMs + 2);
  for (let i = 0; i + 1 < s.sparse.length; i += 2) counts[s.sparse[i]!] = s.sparse[i + 1]!;
  return counts;
}
