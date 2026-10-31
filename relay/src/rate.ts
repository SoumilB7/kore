// Each socket's allowance of frames: a token bucket holding a second's worth, refilled
// continuously (FRAMES_PER_SECOND a second, by the millisecond). A burst over the bucket ends the
// socket, wherever it falls in time; no window boundary lets twice the limit through.
import { FRAMES_PER_SECOND } from "./frame";

export class TokenBucket {
  private tokens: number;
  private at: number;

  constructor(now: number, readonly capacity = FRAMES_PER_SECOND) {
    this.tokens = capacity;
    this.at = now;
  }

  /** Takes one frame's token at `now` (ms); false when there's none left. */
  take(now: number): boolean {
    this.tokens = Math.min(this.capacity, this.tokens + ((now - this.at) * this.capacity) / 1000);
    this.at = now;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }
}
