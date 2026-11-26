(() => {
  'use strict';
  const root = document.documentElement;
  const rm = matchMedia('(prefers-reduced-motion: reduce)');
  const fine = matchMedia('(hover: hover) and (pointer: fine)');

  const clamp = (v, min, max) => Math.min(max, Math.max(min, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const smoothstep = (t) => {
    const c = clamp(t, 0, 1);
    return c * c * (3 - 2 * c);
  };

  if (!rm.matches) {
    root.dataset.appleMotion = 'on';
  }

  // 1. Dynamic frosted header + hairline scroll progress + active nav anchor
  const nav = document.querySelector('.site-nav');
  const navWorkspaceLink = document.querySelector('.nav-links a[href*="#workspace"]');
  const navStudioLink = document.querySelector('.nav-links a[href*="#studio"]');

  const heroIntro = document.querySelector('.hero-intro-scrub');
  const heroStage = document.querySelector('.hero-stage-scrub');
  const workspaceSection = document.querySelector('#workspace');
  const workspaceRunway = document.querySelector('.workspace-sticky-runway');
  const workspaceFigure = document.querySelector('.workspace-figure');
  const finalCta = document.querySelector('.final-cta');

  const parallaxEls = [...document.querySelectorAll('.bento-media[data-parallax]')];
  const scrubFrames = [...document.querySelectorAll('[data-scroll-scrub]')].map(frame => ({
    frame,
    id: frame.dataset.compare,
    kind: frame.dataset.scrollScrub,
    index: Number(frame.dataset.scrubIndex || 0),
    from: Number(frame.dataset.scrubFrom ?? frame.dataset.split ?? 50),
    to: Number(frame.dataset.scrubTo ?? 20)
  }));

  let targetY = scrollY;
  let currentY = scrollY;
  let ticking = false;
  const pendingReveals = new Set();

  function sweepRevealsInView() {
    if (!pendingReveals.size) return;
    const vh = innerHeight || 900;
    for (const el of pendingReveals) {
      if (el.offsetParent === null) continue;
      const r = el.getBoundingClientRect();
      if (r.top < vh * 0.98) {
        el.classList.add('is-visible');
        pendingReveals.delete(el);
      }
    }
  }

  function updateNavAndProgress(y) {
    const max = document.documentElement.scrollHeight - innerHeight;
    root.style.setProperty('--kinetic-progress', max > 0 ? clamp(y / max, 0, 1) : 0);
    if (nav) nav.classList.toggle('is-scrolled', y > 18);

    if (workspaceSection && navWorkspaceLink) {
      const wr = workspaceSection.getBoundingClientRect();
      const sr = document.querySelector('#studio')?.getBoundingClientRect();
      const wsActive = wr.top < innerHeight * 0.45 && wr.bottom > innerHeight * 0.25;
      const stActive = Boolean(sr && sr.height > 40 && sr.top < innerHeight * 0.5 && sr.bottom > innerHeight * 0.2);
      navWorkspaceLink.classList.toggle('is-section-active', wsActive && !stActive);
      if (navStudioLink) navStudioLink.classList.toggle('is-section-active', stActive);
    }
  }

  function applyScrollChoreography(y) {
    updateNavAndProgress(y);
    sweepRevealsInView();
    if (rm.matches) return;

    const vw = innerWidth || 1280;
    const vh = innerHeight || 900;
    const isDesktop = vw >= 960;

    // A. Hero 3D Unfold & Headline Release (0 -> 440px, razor-sharp crisp typography)
    if (heroIntro && vw > 760) {
      const p = clamp(y / 440, 0, 1);
      const eased = smoothstep(p);
      heroIntro.style.transform = `translate3d(0, ${(-eased * 34).toFixed(2)}px, 0) scale(${(1 - eased * 0.032).toFixed(4)})`;
      heroIntro.style.opacity = String((1 - eased * 0.78).toFixed(3));
    } else if (heroIntro) {
      heroIntro.style.transform = '';
      heroIntro.style.opacity = '';
    }

    if (heroStage && vw > 760 && !heroStage.querySelector('.is-comparing')) {
      const p = smoothstep(clamp(y / 360, 0, 1));
      const scale = lerp(0.962, 1.0, p);
      const rx = lerp(4.2, 0, p);
      const sy = lerp(6, -4, p);
      heroStage.style.setProperty('--hero-stage-scale', scale.toFixed(4));
      heroStage.style.setProperty('--hero-rx', `${rx.toFixed(2)}deg`);
      heroStage.style.setProperty('--hero-sy', `${sy.toFixed(2)}px`);
    } else if (heroStage) {
      heroStage.style.setProperty('--hero-stage-scale', '1');
      heroStage.style.setProperty('--hero-rx', '0deg');
      heroStage.style.setProperty('--hero-sy', '0px');
    }

    // B. Sticky #workspace Chapter (Desktop >= 960px)
    if (workspaceRunway && workspaceFigure) {
      if (isDesktop) {
        const rr = workspaceRunway.getBoundingClientRect();
        const travel = Math.max(1, rr.height - vh);
        const stickyP = clamp(-rr.top / travel, 0, 1);

        // Pre-sticky entry unfold before runway locks at top
        const enterP = smoothstep(clamp((vh - rr.top) / (vh * 0.72), 0, 1));
        const rx = lerp(5.2, 0, enterP);
        const scale = lerp(0.93, 1.0, enterP);
        const ty = lerp(26, 0, enterP);
        workspaceFigure.style.setProperty('--ws-rx', `${rx.toFixed(2)}deg`);
        workspaceFigure.style.setProperty('--ws-scale', scale.toFixed(4));
        workspaceFigure.style.setProperty('--ws-y', `${ty.toFixed(2)}px`);
        workspaceRunway.style.setProperty('--ws-progress', stickyP.toFixed(4));

        // Hysteresis prevents flicker around midpoint
        if (window.PhosWorkspace) {
          if (stickyP >= 0.50) {
            window.PhosWorkspace.setModeFromScroll(1);
          } else if (stickyP <= 0.44) {
            window.PhosWorkspace.setModeFromScroll(0);
          }
          const wr = workspaceSection.getBoundingClientRect();
          if (wr.bottom < -vh * 0.6 || wr.top > vh * 1.4) {
            window.PhosWorkspace.resetManual();
          }
        }
      } else {
        workspaceFigure.style.setProperty('--ws-rx', '0deg');
        workspaceFigure.style.setProperty('--ws-scale', '1');
        workspaceFigure.style.setProperty('--ws-y', '0px');
      }
    }

    // C. Pixelmator Pro Style Scroll-Scrubbed Before/After Comparisons
    if (window.PhosCompare) {
      for (const item of scrubFrames) {
        if (window.PhosCompare.isUserControlled(item.id)) continue;
        if (item.kind === 'hero') {
          const t = smoothstep(clamp((y - 14) / 420, 0, 1));
          window.PhosCompare.scrub(item.id, lerp(item.from, item.to, t));
        } else {
          const r = item.frame.getBoundingClientRect();
          // Reveal smoothly as the photo travels through the upper-middle band of the viewport
          const stagger = vw >= 960 ? item.index * 0.08 : 0;
          const raw = (vh * 0.86 - r.top) / (vh * 0.56);
          const t = smoothstep(clamp(raw - stagger, 0, 1));
          window.PhosCompare.scrub(item.id, lerp(item.from, item.to, t));
        }
      }
    }

    // D. Photographic Window Depth Parallax inside Bento Cards
    for (const box of parallaxEls) {
      if (!isDesktop) {
        box.style.setProperty('--px-y', '0px');
        continue;
      }
      const r = box.getBoundingClientRect();
      if (r.bottom < -80 || r.top > vh + 80) continue;
      const center = (r.top + r.height * 0.5) / vh - 0.5;
      const shift = clamp(-center * 24, -14, 14);
      box.style.setProperty('--px-y', `${shift.toFixed(2)}px`);
    }

    // E. Subtle Optical Aperture Glow on Final CTA
    if (finalCta) {
      const cr = finalCta.getBoundingClientRect();
      const glow = smoothstep(clamp((vh - cr.top) / (vh * 0.8), 0, 1));
      finalCta.style.setProperty('--cta-glow', glow.toFixed(3));
    }
  }

  function frame() {
    currentY += (targetY - currentY) * 0.14;
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

  // 2. Masked Keynote Headline Reveals ([data-apple-text])
  const headlineTargets = [
    ...document.querySelectorAll(
      'main .section-heading .section-kicker, main .section-heading h2, main .section-heading p, .final-cta h2, .feature-chapter > h2, .feature-chapter > .chapter-intro, .help-main > section > h2, .design-archive > h2, .design-archive > .lead'
    )
  ];
  headlineTargets.forEach((el) => {
    if (!el.hasAttribute('data-apple-text')) {
      el.setAttribute('data-apple-text', '');
    }
    if (!el.hasAttribute('data-delay')) {
      if (el.matches('h2')) el.dataset.delay = '1';
      else if (el.matches('p, .chapter-intro, .lead')) el.dataset.delay = '2';
    }
  });

  // 3. Staggered Apple Spring Card & Media Reveals ([data-apple-reveal])
  const revealTargets = [
    ...document.querySelectorAll(
      '[data-apple-reveal], main .feature-shot, main .support-card, main .release-card, main .install-shots > figure, main .resource-link, .try-editor, .vs-table-wrap, .faq-list details, .compare-table-wrap'
    )
  ];
  const uniqueReveals = [...new Set(revealTargets)];
  uniqueReveals.forEach((el) => {
    if (!el.hasAttribute('data-apple-reveal')) el.setAttribute('data-apple-reveal', '');
  });

  const allAnimated = [...new Set([...headlineTargets, ...uniqueReveals])];
  if ('IntersectionObserver' in window && !rm.matches) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-visible');
            pendingReveals.delete(entry.target);
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0, rootMargin: '0px 0px -2% 0px' }
    );
    allAnimated.forEach((el) => {
      const r = el.getBoundingClientRect();
      if (r.top < (innerHeight || 900) * 0.98 && r.bottom > -40) {
        el.classList.add('is-visible');
      } else {
        pendingReveals.add(el);
        io.observe(el);
      }
    });
    // Guarantee keyboard Tab focus always lands on visible elements
    document.addEventListener('focusin', (event) => {
      const hit = event.target.closest('[data-apple-reveal], [data-apple-text]');
      if (hit && !hit.classList.contains('is-visible')) {
        hit.classList.add('is-visible');
        pendingReveals.delete(hit);
        io.unobserve(hit);
      }
    });
  } else {
    allAnimated.forEach((el) => el.classList.add('is-visible'));
  }

  // 4. Key Spec Number Count-Up & Zero-Slot Pulse
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
      const p = clamp((now - t0) / dur, 0, 1);
      const eased = 1 - Math.pow(2, -10 * p);
      const val = target * eased;
      el.textContent = `${prefix}${val.toFixed(decimals)}${suffix}`;
      if (p < 1) requestAnimationFrame(step);
      else el.textContent = `${prefix}${target.toFixed(decimals)}${suffix}`;
    }
    requestAnimationFrame(step);
  }

  const zeroPulseEls = [...document.querySelectorAll('.spec-val[data-zero-pulse]')];
  if ('IntersectionObserver' in window && !rm.matches) {
    if (counters.length || zeroPulseEls.length) {
      const cio = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (!entry.isIntersecting) return;
            cio.unobserve(entry.target);
            if (entry.target.hasAttribute('data-count-to')) {
              runCounter(entry.target);
            } else if (entry.target.hasAttribute('data-zero-pulse')) {
              entry.target.classList.add('is-counted');
            }
          });
        },
        { threshold: 0.35 }
      );
      counters.forEach((el) => cio.observe(el));
      zeroPulseEls.forEach((el) => cio.observe(el));
    }
  } else {
    counters.forEach(runCounter);
  }

  // 5. Desktop Pointer Interactions: Liquid Glass 1px Specular, Restrained 3D Tilt (non-comparator), Magnetic CTA
  if (fine.matches && !rm.matches) {
    const specularCards = [...document.querySelectorAll('.spec-card, .bento-card, .ai-demo-card, .look-card, .release-card')];
    const tiltCards = new Set(document.querySelectorAll('.spec-card, .bento-card'));

    specularCards.forEach((card) => {
      card.classList.add('glass-specular');
      if (tiltCards.has(card)) card.classList.add('apple-tilt');

      card.addEventListener(
        'pointermove',
        (e) => {
          const r = card.getBoundingClientRect();
          if (!r.width || !r.height) return;
          const x = e.clientX - r.left;
          const y = e.clientY - r.top;
          card.style.setProperty('--mx', `${x.toFixed(1)}px`);
          card.style.setProperty('--my', `${y.toFixed(1)}px`);
          card.style.setProperty('--spec-op', '1');

          if (tiltCards.has(card)) {
            const nx = (x / r.width) * 2 - 1;
            const ny = (y / r.height) * 2 - 1;
            card.style.setProperty('--tilt-rx', `${(-ny * 1.4).toFixed(2)}deg`);
            card.style.setProperty('--tilt-ry', `${(nx * 1.4).toFixed(2)}deg`);
            card.style.setProperty('--tilt-y', '-2px');
          }
        },
        { passive: true }
      );

      card.addEventListener('pointerleave', () => {
        card.style.setProperty('--spec-op', '0');
        if (tiltCards.has(card)) {
          card.style.setProperty('--tilt-rx', '0deg');
          card.style.setProperty('--tilt-ry', '0deg');
          card.style.setProperty('--tilt-y', '0px');
        }
      });
    });

    // Magnetic micro-pull on primary download buttons
    document.querySelectorAll('a.button.primary[href*="download"]').forEach((btn) => {
      if (btn.closest('.mobile-menu')) return;
      btn.addEventListener(
        'pointermove',
        (e) => {
          const r = btn.getBoundingClientRect();
          if (!r.width || !r.height) return;
          const nx = ((e.clientX - r.left) / r.width) * 2 - 1;
          const ny = ((e.clientY - r.top) / r.height) * 2 - 1;
          btn.style.setProperty('--mag-x', `${clamp(nx * 3.5, -3.5, 3.5).toFixed(2)}px`);
          btn.style.setProperty('--mag-y', `${clamp(ny * 2.5, -2.5, 2.5).toFixed(2)}px`);
        },
        { passive: true }
      );
      btn.addEventListener('pointerleave', () => {
        btn.style.setProperty('--mag-x', '0px');
        btn.style.setProperty('--mag-y', '0px');
      });
    });
  }
})();
