(() => {
  'use strict';
  const root = document.documentElement;
  const rm = matchMedia('(prefers-reduced-motion: reduce)');
  const fine = matchMedia('(hover: hover) and (pointer: fine)');

  if (!rm.matches) {
    root.dataset.appleMotion = 'on';
  }

  // 1. Dynamic frosted header + hairline scroll progress
  const nav = document.querySelector('.site-nav');
  let targetY = scrollY;
  let currentY = scrollY;
  let ticking = false;

  const heroIntro = document.querySelector('.hero-intro-scrub');
  const heroStage = document.querySelector('.hero-stage-scrub');
  const stages = [...document.querySelectorAll('[data-apple-stage]')];

  function updateNavAndProgress(y) {
    const max = document.documentElement.scrollHeight - innerHeight;
    root.style.setProperty('--kinetic-progress', max > 0 ? Math.min(1, Math.max(0, y / max)) : 0);
    if (nav) nav.classList.toggle('is-scrolled', y > 18);
  }

  function applyScrollChoreography(y) {
    updateNavAndProgress(y);
    if (rm.matches) return;

    // Hero parallax fade & stage scale scrub (0 -> 460px)
    if (heroIntro && innerWidth > 760) {
      const p = Math.min(1, Math.max(0, y / 460));
      heroIntro.style.transform = `translate3d(0, ${(-p * 26).toFixed(2)}px, 0) scale(${(1 - p * 0.025).toFixed(4)})`;
      heroIntro.style.opacity = String((1 - p * 0.72).toFixed(3));
    } else if (heroIntro) {
      heroIntro.style.transform = '';
      heroIntro.style.opacity = '';
    }

    if (heroStage && !heroStage.querySelector('.is-comparing') && innerWidth > 760) {
      const p = Math.min(1, Math.max(0, y / 340));
      const scale = 0.965 + p * 0.035;
      heroStage.style.setProperty('--hero-stage-scale', scale.toFixed(4));
    } else if (heroStage) {
      heroStage.style.setProperty('--hero-stage-scale', '1');
    }

    // Scroll-linked showcase stages (e.g., full-width darkroom workspace)
    const vh = innerHeight || 900;
    for (const el of stages) {
      const r = el.getBoundingClientRect();
      // Progress 0 when top enters bottom of viewport, 1 when top reaches ~38% viewport
      const raw = (vh - r.top) / (vh * 0.62);
      const t = Math.min(1, Math.max(0, raw));
      // Smooth cubic ease-out
      const eased = 1 - Math.pow(1 - t, 3);
      const scale = 0.935 + eased * 0.065;
      const ty = (1 - eased) * 28;
      const op = 0.45 + eased * 0.55;
      el.style.setProperty('--stage-scale', scale.toFixed(4));
      el.style.setProperty('--stage-y', `${ty.toFixed(2)}px`);
      el.style.setProperty('--stage-opacity', op.toFixed(3));
    }
  }

  function frame() {
    currentY += (targetY - currentY) * 0.16;
    if (Math.abs(targetY - currentY) < 0.35) {
      currentY = targetY;
      applyScrollChoreography(currentY);
      ticking = false;
      return;
    }
    applyScrollChoreography(currentY);
    requestAnimationFrame(frame);
  }

  function onScroll() {
    targetY = scrollY;
    if (rm.matches) {
      updateNavAndProgress(targetY);
      return;
    }
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(frame);
    }
  }

  addEventListener('scroll', onScroll, { passive: true });
  addEventListener('resize', () => applyScrollChoreography(scrollY), { passive: true });
  applyScrollChoreography(scrollY);

  // 2. Staggered Apple Spring Reveal
  const revealTargets = [
    ...document.querySelectorAll('[data-apple-reveal], main .section-heading, main .feature-shot, main .support-card, main .release-card')
  ];
  const uniqueReveals = [...new Set(revealTargets)];
  uniqueReveals.forEach((el) => {
    if (!el.hasAttribute('data-apple-reveal')) el.setAttribute('data-apple-reveal', '');
  });

  if ('IntersectionObserver' in window && !rm.matches) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-visible');
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.08, rootMargin: '0px 0px -6% 0px' }
    );
    uniqueReveals.forEach((el) => io.observe(el));
  } else {
    uniqueReveals.forEach((el) => el.classList.add('is-visible'));
  }

  // 3. Key Spec Number Count-Up (Apple keynote metric animation)
  const counters = [...document.querySelectorAll('[data-count-to]')];
  function runCounter(el) {
    const target = Number(el.dataset.countTo);
    const decimals = Number(el.dataset.countDecimals || 0);
    const prefix = el.dataset.countPrefix || '';
    const suffix = el.dataset.countSuffix || '';
    if (rm.matches || !Number.isFinite(target) || target === 0) {
      el.textContent = `${prefix}${target.toFixed(decimals)}${suffix}`;
      return;
    }
    const dur = 920;
    const t0 = performance.now();
    function step(now) {
      const p = Math.min(1, (now - t0) / dur);
      const eased = 1 - Math.pow(2, -10 * p);
      const val = target * eased;
      el.textContent = `${prefix}${val.toFixed(decimals)}${suffix}`;
      if (p < 1) requestAnimationFrame(step);
      else el.textContent = `${prefix}${target.toFixed(decimals)}${suffix}`;
    }
    requestAnimationFrame(step);
  }

  if (counters.length) {
    if ('IntersectionObserver' in window && !rm.matches) {
      const cio = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (entry.isIntersecting) {
              runCounter(entry.target);
              cio.unobserve(entry.target);
            }
          });
        },
        { threshold: 0.35 }
      );
      counters.forEach((el) => cio.observe(el));
    } else {
      counters.forEach(runCounter);
    }
  }

  // 4. Liquid Glass 1px Specular Border Tracking (cards only, zero fullscreen glow)
  if (fine.matches && !rm.matches) {
    const cards = [...document.querySelectorAll('.spec-card, .bento-card, .ai-demo-card, .look-card, .release-card')];
    cards.forEach((card) => {
      card.classList.add('glass-specular');
      card.addEventListener(
        'pointermove',
        (e) => {
          const r = card.getBoundingClientRect();
          card.style.setProperty('--mx', `${(e.clientX - r.left).toFixed(1)}px`);
          card.style.setProperty('--my', `${(e.clientY - r.top).toFixed(1)}px`);
          card.style.setProperty('--spec-op', '1');
        },
        { passive: true }
      );
      card.addEventListener('pointerleave', () => {
        card.style.setProperty('--spec-op', '0');
      });
    });
  }
})();
