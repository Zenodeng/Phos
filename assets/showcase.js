(() => {
  'use strict';
  // Real screenshots, same edit state, two native layouts — synced with sticky scroll chapter & manual override.
  const workspaceEl = document.querySelector('#workspace');
  const modes = [...document.querySelectorAll('[data-workspace]')];
  const shots = [...document.querySelectorAll('.workspace-shot')];
  const caption = document.querySelector('#workspaceCaption');
  let currentIndex = Math.max(0, modes.findIndex(b => b.getAttribute('aria-pressed') === 'true'));
  let manualOverride = false;
  let swapTimer = 0;

  function applyMode(index, options = {}) {
    if (!modes[index]) return;
    const fromUser = Boolean(options.fromUser);
    if (fromUser) manualOverride = true;
    if (index === currentIndex && workspaceEl?.dataset.activeMode === modes[index].dataset.workspace) {
      return;
    }
    currentIndex = index;
    const modeName = modes[index].dataset.workspace || (index === 0 ? 'a' : 'b');

    modes.forEach((item, i) => item.setAttribute('aria-pressed', String(i === index)));
    shots.forEach((item, i) => {
      item.classList.toggle('active', i === index);
      item.setAttribute('aria-hidden', String(i !== index));
    });
    if (workspaceEl) {
      workspaceEl.dataset.activeMode = modeName;
    }
    if (caption && caption.dataset[modeName]) {
      const nextText = caption.dataset[modeName];
      if (caption.textContent !== nextText) {
        clearTimeout(swapTimer);
        caption.classList.add('is-swapping');
        swapTimer = window.setTimeout(() => {
          caption.textContent = nextText;
          caption.classList.remove('is-swapping');
        }, 120);
      }
    }
  }

  modes.forEach((button, index) => {
    button.addEventListener('click', () => applyMode(index, { fromUser: true }));
  });

  if (workspaceEl && modes[currentIndex]) {
    workspaceEl.dataset.activeMode = modes[currentIndex].dataset.workspace || 'a';
  }

  window.PhosWorkspace = {
    setModeFromScroll(index) {
      if (manualOverride) return false;
      applyMode(index, { fromUser: false });
      return true;
    },
    resetManual() {
      manualOverride = false;
    },
    isManual() {
      return manualOverride;
    },
    getMode() {
      return currentIndex;
    }
  };
})();
