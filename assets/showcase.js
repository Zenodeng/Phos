(() => {
  'use strict';
  // Real screenshots, same edit state, two native layouts.
  const modes = [...document.querySelectorAll('[data-workspace]')];
  const shots = [...document.querySelectorAll('.workspace-shot')];
  const caption = document.querySelector('#workspaceCaption');
  modes.forEach((button, index) => button.addEventListener('click', () => {
    modes.forEach((item, i) => item.setAttribute('aria-pressed', String(i === index)));
    shots.forEach((item, i) => { item.classList.toggle('active', i === index); item.setAttribute('aria-hidden', String(i !== index)); });
    if (caption) caption.textContent = caption.dataset[button.dataset.workspace];
  }));
})();
