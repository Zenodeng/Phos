(() => {
  'use strict';
  const zh = document.documentElement.lang.startsWith('zh');
  const text = (a,b) => zh?a:b;
  function openDialog(dialog) {
    if (window.PhosMotion) window.PhosMotion.openDialog(dialog);
    else if (!dialog.open) dialog.showModal();
  }
  function closeDialog(dialog) {
    if (window.PhosMotion) window.PhosMotion.closeDialog(dialog);
    else dialog.close();
  }
  function closeButton(dialog) {
    const b=document.createElement('button');b.type='button';b.className='dialog-close';b.textContent=text('关闭','Close');b.setAttribute('aria-label',text('关闭对话框','Close dialog'));b.addEventListener('click',()=>closeDialog(dialog));return b;
  }
  function attachDialog(dialog) {
    document.body.append(dialog);
    dialog.addEventListener('click',e=>{if(e.target===dialog){const r=dialog.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)closeDialog(dialog);}});
    return dialog;
  }
  // One keyboard-searchable directory. Search stays entirely in this page.
  const catalog=[
    ['index.html#workspace','A / B '+text('双布局工作区','workspace'),text('沉浸编辑 连续选片 列表 胶片','Immersive editing filmstrip selection')],
    ['index.html#studio',text('交互试用','Interactive preview'),text('滑杆 曲线 胶片 画笔 蒙版 直方图','Sliders curves film brush masks histogram')],
    ['index.html#gallery',text('样张与胶片风格','Sample edits and film looks'),text('胶片 浓度 样张 对比 Ektar Fuji T-Max','Film intensity sample comparison Ektar Fuji T-Max')],
    ['features.html#screenshots',text('软件工作流截图','Software workflow screenshots'),text('曲线 渐变 导出 放大','Curves gradients export zoom')],
    ['features.html#design',text('石墨 × 香槟金','Graphite & champagne'),text('设计语言 网格 蒙版 控制点','Design language grid mask handles')],
    ['features.html#light',text('明暗与白平衡','Light & white balance'),text('曝光 对比 高光 阴影 色温 色调 自动影调 HDR','Exposure contrast highlights shadows temperature tint auto tone HDR')],
    ['features.html#color',text('曲线与色彩','Curves & color'),text('RGB HSL 颜色分级 黑白 校准','RGB HSL color grading black and white calibration')],
    ['features.html#film',text('胶片与质感','Film & texture'),text('LUT CLUT cube 颗粒 暗角 光晕 锐化 降噪','LUT CLUT cube grain vignette halation sharpening denoise')],
    ['features.html#masks',text('九种局部蒙版','Nine local masks'),text('线性 径向 画笔 范围 主体 人物 抠图 深度','Linear radial brush range subject person cutout depth')],
    ['features.html#geometry',text('裁剪、几何与镜头','Crop, geometry & lenses'),text('画幅 旋转 拉直 自动水平 透视 色差 紫边','Aspect rotation straighten auto level perspective chromatic aberration')],
    ['features.html#workflow',text('选片、预设与批量','Selection, presets & batch'),text('评分 标记 同步 快照 合成','Ratings picks sync snapshots merge')],
    ['features.html#export',text('导出与水印','Export & watermarks'),text('TIFF JPEG PNG HEIC 位深 色域 缩放','TIFF JPEG PNG HEIC bit depth color space resize')],
    ['features.html#local-ai',text('本地 AI 修图','Local AI editing'),text('自然语言 预览 撤销 Qwen 微调','Natural language preview undo Qwen adapter')],
    ['features.html#native',text('原生与中英文界面','Native & bilingual'),text('Swift Core Image Vision English 外观 旁档','Swift Core Image Vision Chinese appearance sidecars')],
    ['help.html#install',text('安装与首次打开','Install & first launch'),text('macOS 公证 安全性 放行','macOS notarization security allow')],
    ['help.html#download-help',text('下载渠道与校验','Mirrors & verification'),'DMG ZIP SHA256 GitHub Cloudflare jsDelivr'],
    ['help.html#ai-model',text('安装可选模型','Install the optional model'),'Python MLX Hugging Face hf-mirror Qwen'],
    ['help.html#windows',text('Windows 实验版','Experimental Windows build'),'Windows 11 x64 SmartScreen'],
    ['index.html#motion-settings',text('网页动效设置','Website motion settings'),text('动画 减少动态 关闭 开启','Animation reduce disable enable')],
    ['index.html#faq',text('常见问题','Frequently asked questions'),text('价格 隐私 格式 相机 系统要求 iPad','Price privacy formats camera requirements iPad')]
  ];
  const command=attachDialog(document.createElement('dialog'));command.className='command-dialog';command.setAttribute('aria-label',text('搜索 Phos 功能与帮助','Search Phos features and help'));
  const header=document.createElement('div');header.className='command-header';
  const input=document.createElement('input');input.className='command-input';input.type='text';input.setAttribute('role','searchbox');input.enterKeyHint='search';input.placeholder=text('搜索功能、工具或安装问题…','Search features, tools or installation…');input.setAttribute('aria-label',input.placeholder);input.autocomplete='off';input.spellcheck=false;
  header.append(input,closeButton(command));const results=document.createElement('div');results.className='command-results';results.setAttribute('aria-live','polite');
  const foot=document.createElement('div');foot.className='command-footer';foot.textContent=text('方向键选择 · Enter 打开 · Esc 关闭 · 仅搜索本站内容','Arrow keys to select · Enter to open · Esc to close · Local site search');command.append(header,results,foot);
  function renderResults(){
    const q=input.value.trim().toLocaleLowerCase();results.replaceChildren();
    const found=catalog.filter(item=>!q||item.slice(1).join(' ').toLocaleLowerCase().includes(q));
    if(!found.length){const p=document.createElement('p');p.className='command-empty';p.textContent=text('没有找到匹配内容，试试“蒙版”“导出”或“模型”。','No matches. Try masks, export or model.');results.append(p);return;}
    found.forEach(([href,title,description])=>{const a=document.createElement('a');a.className='command-result';a.href=href;const left=document.createElement('div'),strong=document.createElement('strong'),small=document.createElement('small'),kind=document.createElement('span');strong.textContent=title;small.textContent=description;kind.textContent=href.startsWith('features')?text('功能','Feature'):href.startsWith('help')?text('帮助','Help'):text('首页','Overview');left.append(strong,small);a.append(left,kind);a.addEventListener('click',()=>closeDialog(command));a.addEventListener('keydown',e=>{if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();const links=[...results.querySelectorAll('a')],i=links.indexOf(a);links[(i+(e.key==='ArrowDown'?1:links.length-1))%links.length].focus();}});results.append(a);});
  }
  function openCommand(){document.querySelectorAll('dialog[open]').forEach(d=>{if(d!==command)closeDialog(d);});input.value='';renderResults();if(!command.open)openDialog(command);input.focus();document.querySelectorAll('.command-trigger').forEach(b=>b.setAttribute('aria-expanded','true'));}
  document.querySelectorAll('.command-trigger').forEach(b=>{b.setAttribute('aria-expanded','false');b.addEventListener('click',openCommand);});command.addEventListener('close',()=>document.querySelectorAll('.command-trigger').forEach(b=>b.setAttribute('aria-expanded','false')));
  input.addEventListener('input',renderResults);input.addEventListener('keydown',e=>{if(e.key==='ArrowDown'||e.key==='Enter'){const first=results.querySelector('a');if(first){e.preventDefault();e.key==='Enter'?first.click():first.focus();}}});
  document.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();command.open?closeDialog(command):openCommand();}});
  // Real image viewer: fit the whole frame or inspect original pixels, including on phones.
  const zoom=attachDialog(document.createElement('dialog'));zoom.className='zoom-dialog';zoom.setAttribute('aria-label',text('工作流大图','Enlarged workflow image'));
  const zoomImg=document.createElement('img'),toolbar=document.createElement('div'),fit=document.createElement('button'),actual=document.createElement('button'),zoomHint=document.createElement('p');
  toolbar.className='zoom-toolbar';fit.type=actual.type='button';fit.textContent=text('适合窗口','Fit');actual.textContent=text('原始尺寸','Actual size');
  fit.className='zoom-fit';actual.className='zoom-actual';zoomHint.className='zoom-hint';zoomHint.textContent=text('原始尺寸，可横向和纵向滚动查看。','Original size. Scroll horizontally and vertically to inspect.');zoomHint.setAttribute('aria-live','polite');
  toolbar.append(fit,actual,closeButton(zoom),zoomHint);const viewport=document.createElement('div');viewport.className='zoom-viewport';viewport.tabIndex=0;viewport.setAttribute('role','region');viewport.setAttribute('aria-label',text('大图，可用方向键滚动查看','Image viewer, use arrow keys to scroll'));viewport.append(zoomImg);zoom.append(toolbar,viewport);
  function setZoom(original){zoom.classList.toggle('is-actual-size',original);fit.setAttribute('aria-pressed',String(!original));actual.setAttribute('aria-pressed',String(original));zoomHint.hidden=!original;}
  fit.addEventListener('click',()=>setZoom(false));actual.addEventListener('click',()=>setZoom(true));setZoom(false);
  document.querySelectorAll('[data-zoom]').forEach(button=>button.addEventListener('click',()=>{
    const frame=button.closest('.gallery-panel, .feature-shot, .workspace-figure'),image=frame.querySelector('img.active')||frame.querySelector('img');
    zoomImg.width=image.naturalWidth||Number(image.getAttribute('width'));zoomImg.height=image.naturalHeight||Number(image.getAttribute('height'));zoomImg.src=image.src;zoomImg.alt=image.alt;setZoom(false);openDialog(zoom);
  }));
  const galleryTabs=[...document.querySelectorAll('[data-gallery]')];galleryTabs.forEach((button,i)=>{
    button.addEventListener('click',()=>{galleryTabs.forEach((b,j)=>{b.setAttribute('aria-selected',String(i===j));b.tabIndex=i===j?0:-1;document.getElementById(b.getAttribute('aria-controls')).hidden=i!==j;});});
    button.addEventListener('keydown',e=>{let n=i;if(e.key==='ArrowRight')n=(i+1)%galleryTabs.length;else if(e.key==='ArrowLeft')n=(i+galleryTabs.length-1)%galleryTabs.length;else if(e.key==='Home')n=0;else if(e.key==='End')n=galleryTabs.length-1;else return;e.preventDefault();galleryTabs[n].click();galleryTabs[n].focus();});
  });
  function revealHash(){
    let hash;try{hash=decodeURIComponent(location.hash.slice(1));}catch{return;}
    const aliases={'original-workflows':'features.html#screenshots','design':'features.html#design','features':'features.html#color','install':'help.html#install','ai-model':'help.html#ai-model','windows':'help.html#windows','motion-preferences':'index.html#motion-settings'};
    const el=document.getElementById(hash);
    if(!el){if(aliases[hash])location.replace(aliases[hash]);return;}
    let parent=el.parentElement,opened=false;
    while(parent){if(parent.tagName==='DETAILS'&&!parent.open){parent.open=true;opened=true;}parent=parent.parentElement;}
    if(opened)requestAnimationFrame(()=>requestAnimationFrame(()=>el.scrollIntoView({behavior:'instant',block:'start'})));
  }
  revealHash();addEventListener('hashchange',revealHash);


  const stage=document.getElementById('stage');if(!stage)return;
  const demo=stage.closest('.demo'),scene=stage.querySelector('.scene');
  let mode='linear',strokes=[],depthStrokes=[],drawing=false,pointer=-1,stroke='',rangePoint=null;
  const paintTools=document.querySelector('.paint-tools'),brushSize=document.getElementById('brushSize'),exp=document.getElementById('rMExp'),feather=document.getElementById('rMFe');
  const brush=document.getElementById('brushEffect'),depth=document.getElementById('depthEffect'),depthPath=document.getElementById('paintRegionPath'),range=document.getElementById('rangeEffect');
  function point(e){const box=stage.getBoundingClientRect(),scale=Math.max(box.width/1200,box.height/760);return{x:(e.clientX-box.left-(box.width-1200*scale)/2)/scale,y:(e.clientY-box.top-(box.height-760*scale)/2)/scale};}
  function updateEffects(){
    const alpha=Math.abs(Number(exp.value))/100*.85;brush.setAttribute('d',strokes.join(' '));brush.setAttribute('stroke',Number(exp.value)<0?'#000':'#fff');brush.setAttribute('stroke-width',brushSize.value);brush.setAttribute('opacity',mode==='brush'?String(alpha):'0');
    depthPath.setAttribute('d',depthStrokes.join(' '));depthPath.setAttribute('stroke-width',brushSize.value);depth.setAttribute('opacity',mode==='depth'?'1':'0');range.setAttribute('opacity',mode==='range'?'1':'0');
  }
  // Only the native application performs Vision inference. The web entry opens its guide.
  const nativeDialog=attachDialog(document.createElement('dialog'));nativeDialog.className='native-info-dialog';nativeDialog.setAttribute('aria-label',text('本地主体与人物选择','Native subject and person selection'));
  nativeDialog.append(closeButton(nativeDialog));const nativeHeading=document.createElement('h2'),nativeCopy=document.createElement('p'),nativeLink=document.createElement('a');nativeHeading.textContent=text('在 Phos 中选择主体。','Select your subject in Phos.');nativeCopy.textContent=text('主体、人物与抠图由 Mac 上的 Vision 完成。网页保留这个功能入口用于介绍，不在浏览器运行原生模型。应用里的蒙版仍可继续反转、复制和调整。','Subject, person and foreground masks use Vision on your Mac. This web entry introduces the feature; it does not run the native model in your browser. Native masks can still be inverted, duplicated and adjusted.');nativeLink.className='text-link';nativeLink.href='features.html#masks';nativeLink.textContent=text('查看九种蒙版的完整说明','Read about all nine mask types');nativeDialog.append(nativeHeading,nativeCopy,nativeLink);
  document.querySelectorAll('.maskrow').forEach(row=>row.addEventListener('click',()=>{
    mode=row.dataset.mask;paintTools.hidden=!['brush','depth'].includes(mode);updateEffects();
    const hints={brush:text('在照片上拖动，试着刷亮或压暗局部；网页为画笔效果示意。可用下方按钮添加中心笔画。','Paint on the photograph to illustrate a local light or dark adjustment. Use the button for a keyboard alternative.'),range:text('点照片取样，预览相近颜色的范围。羽化滑杆在这里控制容差；网页为颜色范围示意。','Click the photo to sample a color and preview similar colors. Feather controls tolerance in this browser illustration.'),ai:text('主体、人物与抠图在应用内由本地 Vision 计算。','Subject, person and cutout selections use on-device Vision in the app.'),depth:text('在照片上涂抹，预览该区域的虚化。原生应用还可读取人像深度数据。','Paint to illustrate blur in that area. The native application can also read portrait depth data.')};
    if(hints[mode])document.getElementById('maskHint').textContent=hints[mode];if(mode==='ai')openDialog(nativeDialog);scheduleHistogram();
  }));
  stage.addEventListener('pointerdown',e=>{if(!['brush','depth','range'].includes(mode))return;e.preventDefault();const p=point(e);if(mode==='range'){rangePoint=p;renderRange();return;}drawing=true;pointer=e.pointerId;stroke=`M${p.x.toFixed(1)} ${p.y.toFixed(1)}`;(mode==='depth'?depthStrokes:strokes).push(stroke);stage.setPointerCapture(pointer);});
  stage.addEventListener('pointermove',e=>{if(!drawing)return;const p=point(e);stroke+=` L${p.x.toFixed(1)} ${p.y.toFixed(1)}`;const list=mode==='depth'?depthStrokes:strokes;list[list.length-1]=stroke;updateEffects();});
  function finish(){if(drawing){drawing=false;if(stage.hasPointerCapture(pointer))stage.releasePointerCapture(pointer);scheduleHistogram();}}
  stage.addEventListener('pointerup',finish);stage.addEventListener('pointercancel',finish);
  document.getElementById('sampleStroke').addEventListener('click',()=>{(mode==='depth'?depthStrokes:strokes).push('M460 400 Q600 270 740 400');updateEffects();scheduleHistogram();});document.getElementById('clearPaint').addEventListener('click',()=>{strokes=[];depthStrokes=[];updateEffects();scheduleHistogram();});
  const baseImage=scene.querySelector('#sceneGroup image')||scene.querySelector('image');
  const baseURL=new URL(baseImage.getAttribute('href'),document.baseURI).href;
  let embeddedPhoto;
  function photoData(){return embeddedPhoto ||= fetch(baseURL).then(r=>{if(!r.ok)throw new Error('Photo unavailable');return r.blob();}).then(blob=>new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=reject;reader.readAsDataURL(blob);}));}

  let samplePixels;
  async function pixels(){if(samplePixels)return samplePixels;const image=new Image();image.src=await photoData();await image.decode();const c=document.createElement('canvas');c.width=360;c.height=228;const ctx=c.getContext('2d',{willReadFrequently:true}),scale=Math.max(c.width/image.width,c.height/image.height);ctx.drawImage(image,(c.width-image.width*scale)/2,(c.height-image.height*scale)/2,image.width*scale,image.height*scale);samplePixels=ctx.getImageData(0,0,c.width,c.height);return samplePixels;}
  async function renderRange(){if(!rangePoint)return;try{const data=await pixels(),x=Math.max(0,Math.min(359,Math.round(rangePoint.x/1200*360))),y=Math.max(0,Math.min(227,Math.round(rangePoint.y/760*228))),ix=(y*360+x)*4;const c=document.createElement('canvas');c.width=360;c.height=228;const ctx=c.getContext('2d'),out=ctx.createImageData(360,228),rgb=[data.data[ix],data.data[ix+1],data.data[ix+2]],tolerance=20+Number(feather.value)*1.5,fill=Number(exp.value)<0?0:255;for(let i=0;i<data.data.length;i+=4){const distance=Math.hypot(data.data[i]-rgb[0],data.data[i+1]-rgb[1],data.data[i+2]-rgb[2]);out.data[i]=out.data[i+1]=out.data[i+2]=fill;out.data[i+3]=Math.max(0,1-distance/tolerance)*Math.abs(Number(exp.value))/100*180;}ctx.putImageData(out,0,0);range.setAttribute('href',c.toDataURL());scheduleHistogram();}catch{document.getElementById('maskHint').textContent=text('无法读取示例图片，仍可试用其他工具。','The sample image could not be read. Other tools remain available.');}}
  [exp,feather,brushSize].forEach(el=>el.addEventListener('input',()=>{updateEffects();if(mode==='range')renderRange();}));
  document.getElementById('resetDemo').addEventListener('click',()=>{strokes=[];depthStrokes=[];rangePoint=null;range.removeAttribute('href');mode='linear';paintTools.hidden=true;updateEffects();scheduleHistogram();});
  // Measure a downsample of the actual filtered browser SVG, not a synthetic distribution.
  const hist=document.getElementById('hist'),status=document.getElementById('histStatus'),badge=document.getElementById('badgeText');const bars=[];for(let i=0;i<56;i++){const bar=document.createElement('i');bar.style.height='64px';bar.style.transformOrigin='bottom';bar.style.transform='scaleY(0.015625)';hist.append(bar);bars.push(bar);}let histTimer=0,sequence=0;
  const editorDisclosure=demo.closest('.try-editor');
  function scheduleHistogram(){clearTimeout(histTimer);if(editorDisclosure&&!editorDisclosure.open)return;histTimer=setTimeout(samplePreview,170);}
  editorDisclosure?.addEventListener('toggle',()=>{if(editorDisclosure.open)scheduleHistogram();});
  async function samplePreview(){const ticket=++sequence;try{const source=await photoData();if(ticket!==sequence)return;const started=performance.now(),clone=scene.cloneNode(true);clone.setAttribute('xmlns','http://www.w3.org/2000/svg');clone.setAttribute('width','360');clone.setAttribute('height','228');clone.removeAttribute('class');clone.querySelector('#guides')?.remove();clone.querySelectorAll('image').forEach(image=>{const href=image.getAttribute('href');if(!href){image.remove();return;}if(!href.startsWith('data:'))image.setAttribute('href',source);});const svg=new XMLSerializer().serializeToString(clone),image=new Image();image.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg);await image.decode();if(ticket!==sequence)return;const canvas=document.createElement('canvas');canvas.width=360;canvas.height=228;const ctx=canvas.getContext('2d',{willReadFrequently:true});ctx.drawImage(image,0,0,360,228);const data=ctx.getImageData(0,0,360,228).data,bins=Array(56).fill(0);for(let i=0;i<data.length;i+=4){if(data[i+3]<128)continue;bins[Math.min(55,Math.floor((data[i]*.2126+data[i+1]*.7152+data[i+2]*.0722)/256*56))]++;}const max=Math.max(...bins,1);bars.forEach((bar,i)=>bar.style.transform=`scaleY(${Math.max(1/64,Math.sqrt(bins[i]/max))})`);hist.dataset.state='ready';hist.dataset.samples=String(bins.reduce((a,b)=>a+b,0));status.textContent=text('亮度分布取自当前网页预览，非原生 RAW 直方图。','Luminance sampled from the browser preview, not the native RAW pipeline.');badge.textContent=text('网页采样 ','Web sample ')+Math.round(performance.now()-started)+' ms · 360 × 228';}catch{hist.dataset.state='unavailable';status.textContent=text('预览直方图暂不可用；其他交互仍可使用。','Preview histogram unavailable; other controls remain available.');badge.textContent=text('网页交互示意','Interactive browser preview');}}
  demo.addEventListener('input',scheduleHistogram);demo.addEventListener('click',scheduleHistogram);demo.addEventListener('pointerup',scheduleHistogram);demo.addEventListener('keydown',scheduleHistogram);scheduleHistogram();
})();
