(() => {
  'use strict';
  const root = document.documentElement;
  const system = matchMedia('(prefers-reduced-motion: reduce)');
  const desktop = matchMedia('(hover: hover) and (pointer: fine) and (min-width: 761px)');
  const ease = 'cubic-bezier(.16,1,.3,1)';
  const easeEnter = 'cubic-bezier(.16,1,.3,1)';
  let enabled = !system.matches;
  const animations = new Set();
  const dialogAnimations = new WeakMap();
  const seen = new WeakSet();
  const queue = [];
  const resets = [];
  let running = 0;

  // Each animation cleans up its temporary styles. The underlying DOM is always readable.
  function animate(element, frames, options = {}, complete) {
    if (!enabled || !element.animate) { if (complete) complete(); return null; }
    const animation = element.animate(frames, {duration:200, easing:ease, fill:'both', ...options});
    animations.add(animation);
    animation.finished.then(() => {
      animations.delete(animation);
      animation.cancel();
      if (complete) complete();
    }, () => animations.delete(animation));
    return animation;
  }

  function openDialog(dialog) {
    const previous = dialogAnimations.get(dialog);
    const initial = dialog.open ? {opacity:getComputedStyle(dialog).opacity,transform:getComputedStyle(dialog).transform} : {opacity:0,transform:'translateY(10px) scale(.99)'};
    if (previous) previous.cancel();
    dialog.classList.remove('motion-closing');
    if (!dialog.open) dialog.showModal();
    const animation = animate(dialog, [initial,{opacity:1,transform:'none'}], {duration:240});
    if (animation) dialogAnimations.set(dialog,animation);
  }
  function closeDialog(dialog) {
    if (!dialog.open) return;
    const initial = {opacity:getComputedStyle(dialog).opacity,transform:getComputedStyle(dialog).transform};
    const previous = dialogAnimations.get(dialog);
    if (previous) previous.cancel();
    if (!enabled || !dialog.animate) { dialog.classList.remove('motion-closing'); dialog.close(); return; }
    dialog.classList.add('motion-closing');
    const animation = animate(dialog, [initial,{opacity:0,transform:'translateY(6px) scale(.995)'}], {duration:200}, () => {
      if (dialogAnimations.get(dialog) !== animation) return;
      dialogAnimations.delete(dialog);
      dialog.classList.remove('motion-closing');
      dialog.close();
    });
    if (animation) dialogAnimations.set(dialog,animation);
  }
  window.PhosMotion = {openDialog,closeDialog,get enabled(){return enabled;}};
  // Search fields may consume native Escape cancellation; make the advertised exit explicit.
  document.addEventListener('keydown',event => {
    if (event.defaultPrevented) return;
    const dialog=document.activeElement?.closest('dialog[open]') || [...document.querySelectorAll('dialog[open]')].at(-1);
    if (!dialog) return;
    if (event.key==='Tab') {
      const items=[...dialog.querySelectorAll('a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])')].filter(el=>el.getClientRects().length&&!el.closest('[hidden],[inert]'));
      const first=items[0],last=items.at(-1),active=document.activeElement;
      if (first && (event.shiftKey ? active===first||!items.includes(active) : active===last||!items.includes(active))) {
        event.preventDefault();(event.shiftKey?last:first).focus();
      }
      return;
    }
    if (['Escape','Esc'].includes(event.key)) { event.preventDefault(); closeDialog(dialog); }
  },{capture:true});
  document.querySelectorAll('dialog').forEach(dialog => {
    dialog.addEventListener('cancel',event => { event.preventDefault(); closeDialog(dialog); });
    dialog.addEventListener('close',() => {
      const animation = dialogAnimations.get(dialog);
      if (animation) animation.cancel();
      dialogAnimations.delete(dialog);
      dialog.classList.remove('motion-closing');
    });
  });

  function applyPreference() {
    enabled = !system.matches;
    root.dataset.motion = enabled ? 'on' : 'off';
    if (!enabled) {
      [...animations].forEach(animation => { try { animation.finish(); } catch (_) { animation.cancel(); } });
      resets.forEach(reset => reset());
    }
  }
  system.addEventListener('change',applyPreference);
  applyPreference();

  // Sole hero entrance: the message, wordmark and download action never wait for motion.
  const product = document.querySelector('.signature-product');
  if (product) {
    animate(product,[{opacity:.55},{opacity:1}],{duration:200});
    let active = false, frame = 0, x = 0, y = 0, box = null;
    function resetTilt() {
      active = false;
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      product.style.transform = '';
      product.classList.remove('is-tilting');
    }
    resets.push(resetTilt);
    desktop.addEventListener('change',resetTilt);
    product.addEventListener('phos:compare-start',resetTilt);
    product.addEventListener('pointerenter',event => {
      if (!enabled || !desktop.matches || event.pointerType !== 'mouse' || product.classList.contains('is-comparing')) return;
      const rect = product.getBoundingClientRect();
      box = {left:rect.left+scrollX,top:rect.top+scrollY,width:rect.width,height:rect.height};
      active = true;
      product.classList.add('is-tilting');
    });
    product.addEventListener('pointermove',event => {
      if (!active || !enabled || !desktop.matches || event.pointerType !== 'mouse' || product.classList.contains('is-comparing')) return;
      x = event.clientX; y = event.clientY;
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        if (!active || !box) return;
        const nx = Math.max(-1,Math.min(1,(x+scrollX-box.left)/box.width*2-1));
        const ny = Math.max(-1,Math.min(1,(y+scrollY-box.top)/box.height*2-1));
        product.style.transform = `perspective(1000px) rotateX(${-ny*3.5}deg) rotateY(${nx*4}deg)`;
      });
    },{passive:true});
    product.addEventListener('pointerleave',resetTilt);
    product.addEventListener('pointercancel',resetTilt);
    addEventListener('blur',resetTilt);
  }

  // One-shot entrances. Groups share a 60ms stagger, capped at 300ms.
  // A two-group queue leaves room for a simultaneous hover or dialog response.
  const specs = new Map();
  function register(element, children = [element], bucket = null) {
    if (!element || specs.has(element)) return;
    element.dataset.motionReveal = 'waiting';
    specs.set(element,{children,bucket});
  }
  document.querySelectorAll('.section-heading').forEach(heading => register(heading,[...heading.children]));
  document.querySelectorAll('.install-shots,.steps,.faq-list,.look-grid').forEach(group => {
    [...group.children].forEach(child => register(child,[child],group));
  });
  document.querySelectorAll('.workspace-figure,.demo,.gallery-tabs,.gallery-panel:not([hidden]),.design-archive>h2,.design-archive>.lead,.anatomy,.precision-copy>h2,.precision-copy>.section-intro,.feature-stories>article,.feature-stories>div,.ai-figure,.ai-benchmark,.ownership-section>h2,.ownership-intro,.faq-section>h2,.install-section>h2,.install-section>.lead,.download-copy,.download-photo,.feature-chapter>h2,.feature-chapter>.chapter-intro,.feature-shot,.original-overview>h2,.feature-original-copy>h2,.help-page main section>h2').forEach(element => register(element));

  document.querySelectorAll('.workflow-look,.workflow-export').forEach(block=>register(block,[...block.children]));
  document.querySelectorAll('.editorial-ai .workflow-copy,.ai-layout>figure,.workflow-refine>.page-width>.section-heading').forEach(element=>register(element));

  // Section text shares one entrance group; avoid animating a parent and child together.
  document.querySelectorAll('.safety-strip,.resource-links,.support-card,.final-cta>.page-width,.help-main>section').forEach(block=>{
    if(!specs.has(block))register(block,[...block.children],block);
  });
  document.querySelectorAll('.workflow-copy,.editorial-ai .workflow-copy').forEach(block=>{
    specs.set(block,{children:[...block.children],bucket:block});
    block.dataset.motionReveal='waiting';
  });

  function pump() {
    while (running < 2 && queue.length) {
      const group=queue.shift();
      const visible=group.items.filter(item => {
        const rect=item.getBoundingClientRect();return rect.bottom>70 && rect.top<innerHeight-12;
      });
      group.items.forEach(item => { item.dataset.motionReveal='done'; });
      if (!enabled || !visible.length || performance.now()-group.time>160) continue;
      running++;
      const targets=visible.flatMap(item=>specs.get(item)?.children || [item]);
      let remaining=targets.length;
      targets.forEach((target,index) => animate(target,[{opacity:0,transform:'translateY(12px)'},{opacity:1,transform:'none'}],{duration:420,easing:easeEnter,delay:Math.min(index*50,250)},() => {
        remaining--; if (!remaining) {running--;pump();}
      }));
    }
  }
  // Full chapter surfaces enter together, including their background and product image.
  // A tall chapter must trigger from its top edge, not a percentage of its full height.
  const chapterSet=new Set(document.querySelectorAll('.workflow-look,.workflow-refine,.workflow-export,.editorial-ai,.learn-section,.final-cta,.safety-strip,.feature-chapter,.workflow-gallery,.help-main>section'));
  document.querySelectorAll('main figure,main .workspace-image,main .install-shots img').forEach(element=>{
    if(element.closest('.photo-hero,.try-editor,dialog,.look-card'))return;
    if(element.matches('img')&&element.closest('figure'))return;
    if(element.matches('.workspace-image')&&element.closest('figure'))return;
    if(element.matches('figure')&&!element.querySelector('img'))return;
    chapterSet.add(element);
  });
  // Observe each complete surface once; nested image observers otherwise snap their parent to its final frame.
  document.querySelectorAll('main>section:not(#gallery):not(#faq),.workflow-refine,.try-editor').forEach(element=>chapterSet.add(element));
  const workspaceSection=document.getElementById('workspace');if(workspaceSection)chapterSet.delete(workspaceSection);
  const topSurfaces=[...chapterSet].filter(element=>![...chapterSet].some(parent=>parent!==element&&parent.contains(element)));
  const chapters=topSurfaces;
  const chapterAnimations=new Map();
  chapters.forEach(chapter=>{
    for(const element of [...specs.keys()])if(element===chapter||chapter.contains(element))specs.delete(element);
    chapter.dataset.chapterEntrance='waiting';
  });
  if('IntersectionObserver' in window){
    const chapterObserver=new IntersectionObserver(entries=>{
      entries.forEach(entry=>{
        if(!entry.isIntersecting)return;
        const chapter=entry.target;chapterObserver.unobserve(chapter);
        if(chapter.dataset.chapterEntrance==='done')return;
        chapter.dataset.chapterEntrance='done';
        if(!enabled)return;
        // Finish an overlapping parent/child entrance before starting the next surface.
        chapterAnimations.forEach((animation,target)=>{
          if(target.contains(chapter)||chapter.contains(target)){animation.finish();chapterAnimations.delete(target);}
        });
        
        const animation=animate(chapter,[{opacity:.15,transform:'translate3d(0,20px,0)'},{opacity:1,transform:'translate3d(0,0,0)'}],{duration:560,easing:easeEnter},()=>chapterAnimations.delete(chapter));
        if(animation)chapterAnimations.set(chapter,animation);
      });
    },{rootMargin:'0px 0px -60px 0px',threshold:0});
    chapters.forEach(chapter=>{
      const rect=chapter.getBoundingClientRect();
      if(rect.top<innerHeight-60&&rect.bottom>0)chapter.dataset.chapterEntrance='done';
      else chapterObserver.observe(chapter);
    });
    document.addEventListener('focusin',event=>{
      chapters.forEach(chapter=>{if(chapter.contains(event.target)){chapterObserver.unobserve(chapter);chapter.dataset.chapterEntrance='done';}});
    });
  }
  if ('IntersectionObserver' in window) {
    const observer=new IntersectionObserver(entries => {
      const batches=new Map();
      entries.forEach(entry => {
        if (!entry.isIntersecting || seen.has(entry.target)) return;
        const element=entry.target,spec=specs.get(element);seen.add(element);observer.unobserve(element);
        if (!enabled) {element.dataset.motionReveal='done';return;}
        const key=spec.bucket || element;
        if (!batches.has(key)) batches.set(key,[]);
        batches.get(key).push(element);
      });
      batches.forEach((items,key) => {
        items.sort((a,b)=>a.getBoundingClientRect().top-b.getBoundingClientRect().top);
        for(let i=0;i<items.length;i+=6)queue.push({items:items.slice(i,i+6),time:performance.now()});
      });
      pump();
    },{rootMargin:'0px 0px -24px 0px',threshold:.06});
    specs.forEach((spec,element) => {
      const rect=element.getBoundingClientRect();
      if (rect.top < innerHeight-24 && rect.bottom>0) {seen.add(element);element.dataset.motionReveal='done';}
      else observer.observe(element);
    });
    document.addEventListener('focusin',event => {
      specs.forEach((spec,element) => {if(element.contains(event.target)){seen.add(element);element.dataset.motionReveal='done';observer.unobserve(element);}});
      animations.forEach(animation => {if(animation.effect?.target?.contains(event.target))animation.finish();});
    });
  }
  document.querySelectorAll('.feature-shot,.gallery-panel,.install-shots>figure,.look-card,.resource-link').forEach(element=>element.classList.add('motion-lift'));

  // A small travelling underline answers a tab selection; photographs crossfade only.
  document.querySelectorAll('.mode-picker,.gallery-tabs,.tabs').forEach(tabs => {
    const indicator=document.createElement('span'); indicator.className='motion-indicator';indicator.setAttribute('aria-hidden','true');
    tabs.classList.add('motion-tabbed');tabs.append(indicator);
    function update() {
      const selected=tabs.querySelector('[aria-selected="true"],[aria-pressed="true"]');
      if (!selected || !tabs.clientWidth) return;
      indicator.style.transform=`translate3d(${selected.offsetLeft}px,${selected.offsetTop+selected.offsetHeight+2}px,0) scaleX(${selected.offsetWidth/tabs.clientWidth})`;
    }
    tabs.addEventListener('click',event => {
      const button=event.target.closest('button'); if(!button) return;
      update();
      if(tabs.classList.contains('gallery-tabs')){
        const panel=document.getElementById(button.getAttribute('aria-controls'));
        if(panel)animate(panel,[{opacity:.35},{opacity:1}]);
      }
      if(tabs.classList.contains('tabs')){
        const panel=document.getElementById(button.getAttribute('aria-controls'));
        if(panel)animate(panel,[{opacity:.35},{opacity:1}]);
      }
    });
    if('ResizeObserver' in window)new ResizeObserver(update).observe(tabs);
    document.fonts?.ready.then(update);update();
  });

  // Native disclosure state changes once; only its content fades and translates.
  document.querySelectorAll('details:not(.chapter-menu)').forEach(details => {
    const summary=details.querySelector(':scope > summary'); if(!summary) return;
    const contentNodes=[...details.childNodes].filter(node=>node!==summary && (node.nodeType===1 || node.textContent.trim()));
    if(!contentNodes.length)return;
    let content;
    if(contentNodes.length===1 && contentNodes[0].nodeType===1)content=contentNodes[0];
    else {content=document.createElement('div');contentNodes.forEach(node=>content.append(node));details.append(content);}
    content.classList.add('motion-details-content');
    let desired=details.open,animation=null,version=0;
    summary.addEventListener('click',event => {
      if(event.target.closest('a,button,input'))return;
      event.preventDefault();desired=animation ? !desired : !details.open;const token=++version;
      if(animation)animation.cancel();animation=null;
      if(!enabled){details.open=desired;content.inert=false;return;}
      if(desired){
        details.open=true;content.inert=false;
        animation=animate(content,[{opacity:0,transform:'translateY(-6px)'},{opacity:1,transform:'none'}],{duration:200},()=>{if(token===version)animation=null;});
      }else{
        content.inert=true;
        animation=animate(content,[{opacity:1,transform:'none'},{opacity:0,transform:'translateY(-6px)'}],{duration:160},()=>{
          if(token!==version)return;details.open=false;content.inert=false;animation=null;
        });
      }
    });
  });
})();
