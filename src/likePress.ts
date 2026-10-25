export const LIKE_HOLD_MS = 800;
export const LIKE_CHARGE_MS = 1600;

/** Native click follows pointerup: consume it after a hold or cancelled gesture. */
export function createLikePress(onClick: () => void, onHold: () => void, onHolding: (holding: boolean) => void, canHold = () => true) {
  let timer: ReturnType<typeof setTimeout> | undefined, active = false, consumed = false;
  const clear = () => { clearTimeout(timer); timer = undefined; onHolding(false); };
  return {
    start() {
      if (active) return;
      active = true; consumed = false;
      timer = setTimeout(() => {
        if (!active) return;
        consumed = true;
        if (!canHold()) { active = false; timer = undefined; return; }
        onHolding(true);
        timer = setTimeout(() => { if (active) { active = false; timer = undefined; onHolding(false); onHold(); } }, LIKE_CHARGE_MS);
      }, LIKE_HOLD_MS);
    },
    end() { active = false; clear(); },
    cancel() { if (active) consumed = true; active = false; clear(); },
    click() { if (consumed) { consumed = false; return; } onClick(); },
    dispose() { active = false; clearTimeout(timer); },
  };
}
