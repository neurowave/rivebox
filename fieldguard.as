// fieldguard.as — wraps the player-name TextInput (AnimaScript port of
// fieldguard.luau). A focused TextInput keeps every key, so this layout sits
// on its ancestor chain: when Escape / Enter / Tab bubble up (or arrive while
// the field is focused) it fires the `fieldDone` trigger, and the state
// machine hands focus back to the dashboard.

import { Layout, Context } from "rive/host";
import { PropertyTrigger } from "rive/data";
import { KeyboardEvent } from "rive/events";

export class FieldGuard extends Layout {
    done: PropertyTrigger? = null;

    override init(context: Context): bool {
        let vm = context.rootViewModel();
        if (vm != null) {
            this.done = vm.getTrigger("fieldDone");
        }
        return true;
    }

    override keyboardEvent(e: KeyboardEvent): bool {
        // 256 escape, 257 enter, 258 tab, 335 keypad enter (GLFW codes)
        if (e.phase == "down" && (e.key == 256 || e.key == 257 || e.key == 258 || e.key == 335)) {
            let d = this.done;
            if (d != null) {
                d.fire();
            }
            return true;
        }
        return false;
    }
}
