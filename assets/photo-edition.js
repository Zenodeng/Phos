(() => {
  'use strict';
  const zh=document.documentElement.lang.startsWith('zh');
  const comparators=new Map();
  document.querySelectorAll('[data-compare]').forEach(frame=>{
    const input=frame.querySelector('.compare-range'),before=frame.querySelector('.compare-before'),image=before.querySelector('img'),divider=frame.querySelector('.compare-divider');
    let value=Number(input.value),width=frame.clientWidth;
    function update(next){
      value=Math.max(0,Math.min(100,Number(next)));input.value=String(value);
      before.style.transform=`translateX(${value-100}%)`;
      image.style.transform=`translateX(${100-value}%)`;
      divider.style.transform=`translate3d(${width*value/100}px,0,0)`;
      divider.style.opacity=value===0||value===100?'0':'1';
      input.setAttribute('aria-valuetext',zh?`编辑前 ${value}%，修后 ${100-value}%`:`${value}% before, ${100-value}% after`);
      document.querySelectorAll(`[data-for="${frame.dataset.compare}"] button`).forEach(button=>button.setAttribute('aria-pressed',String(Number(button.dataset.show)===value)));
      frame.dataset.position=String(value);
    }
    function hold(){frame.classList.add('is-comparing');frame.closest('.look-card')?.classList.add('is-interacting');frame.dispatchEvent(new CustomEvent('phos:compare-start'));}
    function release(){if(document.activeElement!==input){frame.classList.remove('is-comparing');frame.closest('.look-card')?.classList.remove('is-interacting');}}
    frame.addEventListener('pointerdown',hold,{capture:true});
    input.addEventListener('focus',hold);input.addEventListener('blur',release);
    input.addEventListener('input',()=>update(input.value));input.addEventListener('pointerup',release);input.addEventListener('pointercancel',release);
    if('ResizeObserver' in window)new ResizeObserver(()=>{width=frame.clientWidth;update(value);}).observe(frame);
    frame.classList.add('compare-ready');update(value);comparators.set(frame.dataset.compare,{frame,input,update});
  });
  document.querySelectorAll('.compare-actions').forEach(group=>{
    group.classList.add('is-ready');group.querySelectorAll('button').forEach(button=>button.addEventListener('click',()=>comparators.get(group.dataset.for)?.update(button.dataset.show)));
  });
})();
