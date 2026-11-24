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
  const sidebarNav=document.querySelector('.feature-sidebar > nav');
  const sections=[...document.querySelectorAll('.feature-chapter')];
  if(sidebarNav&&sections.length){
    const allSidebarLinks=[...document.querySelectorAll('.feature-sidebar a[href^="#"]')];
    let rafId=0;
    const setActive=id=>{
      allSidebarLinks.forEach(a=>{
        if(a.hash==='#'+id)a.setAttribute('aria-current','location');
        else a.removeAttribute('aria-current');
      });
    };
    const updateActive=()=>{
      rafId=0;
      const atBottom=window.innerHeight+window.scrollY>=document.documentElement.scrollHeight-40;
      if(atBottom){setActive(sections[sections.length-1].id);return;}
      let current=sections[0].id;
      for(const section of sections){
        if(section.getBoundingClientRect().top<=140)current=section.id;
        else break;
      }
      setActive(current);
    };
    const scheduleUpdate=()=>{if(!rafId)rafId=requestAnimationFrame(updateActive);};
    window.addEventListener('scroll',scheduleUpdate,{passive:true});
    window.addEventListener('resize',scheduleUpdate,{passive:true});
    window.addEventListener('hashchange',scheduleUpdate);
    updateActive();
  }
})();
