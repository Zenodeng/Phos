(() => {
  'use strict';
  const menu=document.getElementById('mobile-menu');
  const trigger=document.querySelector('.menu-toggle');
  const close=dialog=>window.PhosMotion?window.PhosMotion.closeDialog(dialog):dialog.close();
  const open=dialog=>window.PhosMotion?window.PhosMotion.openDialog(dialog):dialog.showModal();
  if(menu&&trigger){
    trigger.hidden=false;
    trigger.addEventListener('click',()=>{
      if(menu.open){close(menu);return;}
      document.querySelectorAll('dialog[open]').forEach(d=>close(d));
      open(menu);trigger.setAttribute('aria-expanded','true');menu.querySelector('.menu-close').focus();
    });
    menu.querySelector('.menu-close').addEventListener('click',()=>close(menu));
    menu.querySelectorAll('a').forEach(a=>a.addEventListener('click',()=>close(menu)));
    menu.addEventListener('click',event=>{if(event.target!==menu)return;const r=menu.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)close(menu);});
    menu.addEventListener('close',()=>{trigger.setAttribute('aria-expanded','false');if(matchMedia('(max-width:760px)').matches)trigger.focus({preventScroll:true});});
    matchMedia('(min-width:761px)').addEventListener('change',event=>{if(event.matches&&menu.open)close(menu);});
  }
  document.querySelectorAll('.chapter-menu a').forEach(link=>link.addEventListener('click',()=>{link.closest('details').open=false;}));
  const sections=[...document.querySelectorAll('.feature-chapter')];
  if(sections.length&&'IntersectionObserver' in window){
    const observer=new IntersectionObserver(entries=>{for(const entry of entries)if(entry.isIntersecting){document.querySelectorAll('.feature-sidebar a[href^="#"]').forEach(a=>{if(a.hash==='#'+entry.target.id)a.setAttribute('aria-current','location');else a.removeAttribute('aria-current');});}},{rootMargin:'-90px 0px -65% 0px'});
    sections.forEach(section=>observer.observe(section));
  }
})();
