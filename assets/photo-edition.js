(() => {
  'use strict';
  const zh = document.documentElement.lang.startsWith('zh');
  const rm = matchMedia('(prefers-reduced-motion: reduce)');
  const comparators = new Map();

  function syncButtons(id, targetPct, forceExact) {
    const buttons = document.querySelectorAll(`[data-for="${id}"] button`);
    if (!buttons.length) return;
    let activeTarget = null;
    if (forceExact) {
      activeTarget = Math.round(targetPct);
    } else if (targetPct <= 14) {
      activeTarget = 0;
    } else if (targetPct >= 86) {
      activeTarget = 100;
    } else {
      activeTarget = 50;
    }
    buttons.forEach(button => {
      const expected = String(Number(button.dataset.show) === activeTarget);
      if (button.getAttribute('aria-pressed') !== expected) {
        button.setAttribute('aria-pressed', expected);
      }
    });
  }

  document.querySelectorAll('[data-compare]').forEach(frame => {
    const id = frame.dataset.compare;
    const input = frame.querySelector('.compare-range');
    const before = frame.querySelector('.compare-before');
    const image = before?.querySelector('img');
    const divider = frame.querySelector('.compare-divider');
    if (!input || !before || !image || !divider) return;

    const state = {
      id,
      frame,
      input,
      value: Number(input.value),
      target: Number(input.value),
      velocity: 0,
      rafId: 0,
      lastTime: 0,
      width: frame.clientWidth || 1,
      userControlled: false,
      lastBand: ''
    };

    function render(nextVal) {
      const v = Math.max(0, Math.min(100, Number(nextVal)));
      state.value = v;
      const rounded = Math.round(v);
      input.value = String(rounded);
      before.style.transform = `translate3d(${(v - 100).toFixed(3)}%,0,0)`;
      image.style.transform = `translate3d(${(100 - v).toFixed(3)}%,0,0)`;
      divider.style.transform = `translate3d(${((state.width * v) / 100).toFixed(2)}px,0,0)`;
      divider.style.opacity = (v <= 0.4 || v >= 99.6) ? '0' : '1';
      input.setAttribute(
        'aria-valuetext',
        zh ? `编辑前 ${rounded}%，修后 ${100 - rounded}%` : `${rounded}% before, ${100 - rounded}% after`
      );
      frame.dataset.position = String(rounded);
    }

    function stopSpring() {
      if (state.rafId) {
        cancelAnimationFrame(state.rafId);
        state.rafId = 0;
      }
      state.velocity = 0;
      state.lastTime = 0;
    }

    function animateTo(targetVal, options = {}) {
      const clamped = Math.max(0, Math.min(100, Number(targetVal)));
      const fromUser = options.fromUser !== false;
      if (fromUser) state.userControlled = true;
      state.target = clamped;
      syncButtons(id, clamped, true);

      if (rm.matches || document.documentElement.dataset.motion === 'off') {
        stopSpring();
        render(clamped);
        return;
      }

      if (Math.abs(state.value - clamped) < 0.08 && Math.abs(state.velocity) < 0.2) {
        stopSpring();
        render(clamped);
        return;
      }

      if (state.rafId) return;
      state.lastTime = performance.now();
      const stiffness = 210;
      const damping = 26;

      const step = (now) => {
        const dt = Math.min(0.032, Math.max(0.001, (now - state.lastTime) / 1000));
        state.lastTime = now;
        const force = (state.target - state.value) * stiffness;
        const accel = force - state.velocity * damping;
        state.velocity += accel * dt;
        const next = state.value + state.velocity * dt;

        if (Math.abs(state.target - next) < 0.06 && Math.abs(state.velocity) < 0.35) {
          state.rafId = 0;
          state.velocity = 0;
          render(state.target);
          return;
        }
        render(next);
        state.rafId = requestAnimationFrame(step);
      };
      state.rafId = requestAnimationFrame(step);
    }

    function scrub(targetVal) {
      if (state.userControlled) return false;
      stopSpring();
      const clamped = Math.max(0, Math.min(100, Number(targetVal)));
      render(clamped);
      const band = clamped <= 14 ? 'after' : clamped >= 86 ? 'before' : 'mid';
      if (band !== state.lastBand) {
        state.lastBand = band;
        syncButtons(id, clamped, false);
      }
      return true;
    }

    function updateInstant(next, markUser = false) {
      stopSpring();
      if (markUser) state.userControlled = true;
      const v = Math.max(0, Math.min(100, Number(next)));
      state.target = v;
      render(v);
      syncButtons(id, v, markUser);
    }

    function hold() {
      state.userControlled = true;
      stopSpring();
      frame.classList.add('is-comparing');
      frame.closest('.look-card, .ai-demo-card')?.classList.add('is-interacting');
      frame.dispatchEvent(new CustomEvent('phos:compare-start'));
    }

    function release() {
      if (document.activeElement !== input) {
        frame.classList.remove('is-comparing');
        frame.closest('.look-card, .ai-demo-card')?.classList.remove('is-interacting');
        frame.dispatchEvent(new CustomEvent('phos:compare-end'));
      }
    }

    frame.addEventListener('pointerdown', hold, { capture: true });
    input.addEventListener('focus', hold);
    input.addEventListener('blur', () => {
      frame.classList.remove('is-comparing');
      frame.closest('.look-card, .ai-demo-card')?.classList.remove('is-interacting');
      frame.dispatchEvent(new CustomEvent('phos:compare-end'));
    });
    input.addEventListener('input', () => updateInstant(input.value, true));
    input.addEventListener('pointerup', release);
    input.addEventListener('pointercancel', release);

    if ('ResizeObserver' in window) {
      new ResizeObserver(() => {
        state.width = frame.clientWidth || 1;
        render(state.value);
      }).observe(frame);
    }

    frame.classList.add('compare-ready');
    render(state.value);
    syncButtons(id, state.value, true);
    comparators.set(id, {
      frame,
      input,
      state,
      update: (next) => updateInstant(next, true),
      animateTo,
      scrub,
      isUserControlled: () => state.userControlled
    });
  });

  document.querySelectorAll('.compare-actions').forEach(group => {
    group.classList.add('is-ready');
    group.querySelectorAll('button').forEach(button => {
      button.addEventListener('click', () => {
        const comp = comparators.get(group.dataset.for);
        if (comp) comp.animateTo(button.dataset.show, { fromUser: true });
      });
    });
  });

  window.PhosCompare = {
    scrub: (id, pct) => comparators.get(id)?.scrub(pct) ?? false,
    animateTo: (id, pct, opts) => comparators.get(id)?.animateTo(pct, opts),
    isUserControlled: (id) => comparators.get(id)?.isUserControlled() ?? true,
    get: (id) => comparators.get(id)
  };
})();
