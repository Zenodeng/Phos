(() => {
  'use strict';

  const seams = [...document.querySelectorAll('[data-seam]')];
  if (!seams.length) return;

  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = matchMedia('(hover: hover) and (pointer: fine)');
  const activeTimers = new WeakMap();

  function animateIn(seam) {
    if (seam.classList.contains('is-lit')) return;
    const timer = activeTimers.get(seam);
    if (timer) clearTimeout(timer);
    seam.classList.add('is-animating');
    requestAnimationFrame(() => seam.classList.add('is-lit'));
    activeTimers.set(seam, setTimeout(() => seam.classList.remove('is-animating'), reduce.matches ? 160 : 680));
  }

  function nearestEdge(seam, event) {
    const rect = seam.getBoundingClientRect();
    const distances = [
      {edge: 'top', value: Math.abs(event.clientY - rect.top)},
      {edge: 'right', value: Math.abs(rect.right - event.clientX)},
      {edge: 'bottom', value: Math.abs(rect.bottom - event.clientY)},
      {edge: 'left', value: Math.abs(event.clientX - rect.left)}
    ];
    return distances.sort((a, b) => a.value - b.value)[0].edge;
  }

  function updatePointer(seam, event) {
    const rect = seam.getBoundingClientRect();
    seam.style.setProperty('--seam-x', `${Math.max(0, Math.min(100, ((event.clientX - rect.left) / rect.width) * 100))}%`);
    seam.style.setProperty('--seam-y', `${Math.max(0, Math.min(100, ((event.clientY - rect.top) / rect.height) * 100))}%`);
  }

  function bindHover(seam) {
    const trigger = seam.dataset.trigger;
    if (!finePointer.matches || (trigger !== 'hover' && seam.matches('.photo-comparison'))) return;
    let frame = 0;
    let lastEvent;
    let clearTimer;
    const onMove = event => {
      if (event.pointerType && event.pointerType !== 'mouse') return;
      lastEvent = event;
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        if (lastEvent) updatePointer(seam, lastEvent);
      });
    };
    seam.addEventListener('pointerenter', event => {
      if (event.pointerType && event.pointerType !== 'mouse') return;
      updatePointer(seam, event);
      seam.classList.add('is-hovering');
      clearTimeout(clearTimer);
    }, {passive: true});
    seam.addEventListener('pointermove', onMove, {passive: true});
    seam.addEventListener('pointerleave', () => {
      seam.classList.remove('is-hovering');
      clearTimer = setTimeout(() => seam.style.removeProperty('--seam-x'), 220);
    }, {passive: true});
  }

  function bindFocus(seam) {
    seam.addEventListener('focusin', () => seam.classList.add('is-focus-seam'));
    seam.addEventListener('focusout', event => {
      if (!seam.contains(event.relatedTarget)) seam.classList.remove('is-focus-seam');
    });
  }

  function bindDrag(seam) {
    if (!seam.matches('.photo-comparison')) return;
    const divider = seam.querySelector('.compare-divider');
    const input = seam.querySelector('.compare-range');
    if (!divider || !input) return;
    divider.classList.add('seam-divider');
    const charge = () => {
      divider.classList.add('is-charged');
      seam.classList.add('is-dragging');
    };
    const settle = () => {
      divider.classList.remove('is-charged');
      seam.classList.remove('is-dragging');
    };
    input.addEventListener('pointerdown', charge, {passive: true});
    input.addEventListener('pointerup', settle, {passive: true});
    input.addEventListener('pointercancel', settle, {passive: true});
    input.addEventListener('blur', settle);
    seam.addEventListener('phos:compare-start', charge);
    seam.addEventListener('phos:compare-end', settle);
  }

  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (!entry.isIntersecting) return;
        observer.unobserve(entry.target);
        window.setTimeout(() => animateIn(entry.target), 100);
      });
    }, {rootMargin: '0px 0px -12% 0px', threshold: .04});
    seams.forEach(seam => observer.observe(seam));
  } else {
    seams.forEach(animateIn);
  }

  seams.forEach(seam => {
    bindHover(seam);
    bindFocus(seam);
    bindDrag(seam);
  });
})();
