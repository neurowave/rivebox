// decrypt.as — Decrypt: a scripted data converter for text binds
// (AnimaScript port of decrypt.luau).
//
// Every UI string in RiveBox flows through this converter on its way from the
// view model to its TextValueRun. When the value changes (a new game is
// selected, a clock ticks) or the screen it lives on appears (the dashboard
// `mode` changes, or the section changes while inside one), the string
// re-plays a decrypt: the full string appears at once as cipher noise, then a
// front sweeps left -> right resolving the noise into the real characters
// (with a short flicker zone ahead of the front). The string is full length
// from the first frame, so layouts never reflow while it plays.
// Noise keeps each character's class (A-Z stays upper, a-z lower, digits
// digits) so proportional fonts barely reflow, and spaces/punctuation are kept
// so words hold their shape while they scramble.
//
// One converter element serves every bind; the runtime makes one instance per
// bind, so each string animates on its own clock (with a small per-instance
// stagger so a whole screen doesn't flip in lockstep).
//
// Text is processed as UTF-8 bytes, exactly like the Luau original: bytes
// above 127 pass through untouched and count toward the reveal front.

import { Converter, Context } from "rive/host";
import { DataValue, DataValueString } from "rive/data_value";
import { PropertyNumber } from "rive/data";
import { Buffer } from "rive/buffer";

const UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#%&*+=<>/";
const LOWER = "abcdefghijklmnopqrstuvwxyz";
const DIGIT = "0123456789";

// one counter for every Decrypt instance (Luau's file-level `local count`)
let count: i32 = 0;

// integer hash -> [0, 1)
function hash(n: f64): f64 {
    let x = Math.sin(n * 12.9898 + 78.233) * 43758.5453;
    return x - Math.floor(x);
}

function clamp(x: f64, lo: f64, hi: f64): f64 {
    return x < lo ? lo : (x > hi ? hi : x);
}

export class Decrypt extends Converter {
    ctx: Context? = null;
    pMode: PropertyNumber? = null;
    pSec: PropertyNumber? = null;
    pCue: PropertyNumber? = null;
    lastCue: f64 = 0;
    // encrypt-out when leaving for the start screen (mode -> 0)
    leaving: bool = false;
    lt: f64 = 0;
    outMode: f64 = 0;
    lastMode: f64 = 0;
    lastSec: f64 = 0;
    target: string = "";
    t: f64 = 0;
    delay: f64 = 0;
    done: bool = false;
    id: f64 = 0;

    restart(): void {
        this.t = 0;
        this.done = false;
        this.leaving = false;
        let c = this.ctx;
        if (c != null) {
            c.markNeedsUpdate();
        }
    }

    override init(context: Context): bool {
        count += 1;
        this.id = <f64>count;
        this.ctx = context;
        // small golden-ratio stagger per bind, 0..0.22 s
        let g = <f64>count * 0.6180339887;
        this.delay = (g - Math.floor(g)) * 0.22;
        let vm = context.viewModel();
        if (vm != null) {
            // dashboard VM has mode/section; list rows carry hMode/hSection mirrors
            this.pCue = vm.getNumber("cue");
            let pm = vm.getNumber("mode");
            this.pMode = pm != null ? pm : vm.getNumber("hMode");
            let ps = vm.getNumber("section");
            this.pSec = ps != null ? ps : vm.getNumber("hSection");
        }
        let pc = this.pCue;
        this.lastCue = pc != null ? pc.value : 0;
        if (pc == null) {
            // list rows have no cue: they key off the mode mirror, a beat later
            // so they land after their screen has glitched in
            this.delay += 0.35;
        }
        let pm = this.pMode, ps = this.pSec;
        this.lastMode = pm != null ? pm.value : 0;
        this.lastSec = ps != null ? ps.value : 0;
        return true;
    }

    override convert(input: DataValue): DataValue? {
        if (!input.isString()) {
            return input;
        }
        let s = (<DataValueString>input).value;
        if (s != this.target) {
            this.target = s;
            this.restart();
        }
        let bytes = Buffer.fromstring(s);
        let n = <i32>bytes.byteLength;
        if (this.leaving && n > 0) {
            // encrypt out: a noise front sweeps left -> right, a second front a
            // beat behind blanks the noise (spaces keep the layout still)
            let lt = this.lt - this.delay * 0.5;
            let cps = clamp(<f64>n / 0.3, 30, 140);
            let step = Math.floor(this.lt * 30);
            let out = Buffer.create(n);
            for (let i = 1; i <= n; i++) {
                let b = <i32>Buffer.readu8(bytes, i - 1);
                let tNoise = <f64>(i - 1) / (cps * 1.6);
                let tGone = 0.16 + <f64>(i - 1) / cps;
                if (lt >= tGone) {
                    Buffer.writeu8(out, i - 1, 32);
                } else if (lt >= tNoise && b != 32 && b <= 127) {
                    let r = hash(<f64>i * 173 + step * 6271 + this.id * 17);
                    let pool = (b >= 97 && b <= 122) ? LOWER : ((b >= 48 && b <= 57) ? DIGIT : UPPER);
                    let k = <i32>Math.floor(r * <f64>pool.length);
                    Buffer.writeu8(out, i - 1, pool.charCodeAt(k));
                } else {
                    Buffer.writeu8(out, i - 1, b);
                }
            }
            return new DataValueString(Buffer.tostring(out));
        }
        if (this.done || n == 0) {
            return new DataValueString(s);
        }
        let t = this.t;
        // speed scales with length so short labels and long blurbs both land in
        // roughly 0.35-0.9 s
        let cps = clamp(<f64>n / 0.45, 24, 110);
        let hold = 0.12 + this.delay;
        let step = Math.floor(this.t * 30); // noise re-rolls at 30 Hz
        let out = Buffer.create(n);
        let all = true;
        for (let i = 1; i <= n; i++) {
            let b = <i32>Buffer.readu8(bytes, i - 1);
            let tResolve = hold + <f64>(i - 1) / cps;
            if (t >= tResolve || b == 32 || b > 127) {
                Buffer.writeu8(out, i - 1, b);
            } else {
                all = false;
                let r = hash(<f64>i * 131 + step * 7919 + this.id * 31);
                let pool = "";
                if (b >= 65 && b <= 90) {
                    pool = UPPER;
                } else if (b >= 97 && b <= 122) {
                    pool = LOWER;
                } else if (b >= 48 && b <= 57) {
                    pool = DIGIT;
                }
                if (pool.length > 0) {
                    let k = <i32>Math.floor(r * <f64>pool.length);
                    Buffer.writeu8(out, i - 1, pool.charCodeAt(k));
                } else {
                    Buffer.writeu8(out, i - 1, b);
                }
            }
        }
        if (all) {
            this.done = true;
            return new DataValueString(s);
        }
        return new DataValueString(Buffer.tostring(out));
    }

    override reverseConvert(input: DataValue): DataValue? {
        return input;
    }

    override advance(seconds: f64): bool {
        // replay when the camera arrives at the screen this text lives on
        let pc = this.pCue;
        if (pc != null) {
            if (pc.value != this.lastCue) {
                this.lastCue = pc.value;
                this.restart();
            }
        }
        let pm = this.pMode, ps = this.pSec;
        // leaving for the start screen: encrypt out (both kinds of bind)
        if (pm != null) {
            let m = pm.value;
            if (m == 0 && this.outMode != 0 && !this.leaving) {
                this.leaving = true;
                this.lt = 0;
            } else if (m != 0 && this.leaving) {
                // back from the start screen: decrypt in again. (Cue-bound text
                // also restarts on the next arrival cue; list rows have no cue
                // and would otherwise stay blank.)
                this.restart();
            }
            this.outMode = m;
            if (this.leaving && pc == null) {
                this.lastMode = m;
            }
        }
        if (this.leaving) {
            this.lt += seconds;
            if (this.lt < 2) {
                let c = this.ctx;
                if (c != null) {
                    c.markNeedsUpdate();
                }
            }
            return true;
        }
        if (pc == null && pm != null) {
            let m = pm.value;
            let sec = ps != null ? ps.value : 0;
            let changed = m != this.lastMode || (m >= 2 && sec != this.lastSec);
            this.lastMode = m;
            this.lastSec = sec;
            if (changed) {
                this.restart();
            }
        }
        if (!this.done) {
            this.t += seconds;
            let c = this.ctx;
            if (c != null) {
                c.markNeedsUpdate();
            }
        }
        return true;
    }
}
