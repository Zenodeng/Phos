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
    ['index.html#workspace','A / B '+text('双布局工作区','workspace'),text('沉浸编辑 连续选片 列表 胶片 多视图 网格 对比 参考视图','Immersive editing filmstrip selection grid compare survey reference')],
    ['index.html#studio',text('交互试用','Interactive preview'),text('滑杆 曲线 胶片 画笔 蒙版 直方图','Sliders curves film brush masks histogram')],
    ['index.html#gallery',text('样张与胶片风格','Sample edits and film looks'),text('胶片 浓度 样张 对比 Ektar Fuji T-Max HALD CLUT','Film intensity sample comparison Ektar Fuji T-Max HALD CLUT')],
    ['features.html#screenshots',text('软件工作流截图','Software workflow screenshots'),text('曲线 渐变 导出 放大','Curves gradients export zoom')],
    ['features.html#design',text('暗房界面与液态玻璃','Darkroom UI & Liquid Glass'),text('设计语言 网格 蒙版 控制点 液态玻璃 无彩色','Design language grid mask handles Liquid Glass achromatic')],
    ['features.html#light',text('明暗、16-bit Metal 与 EDR','Light, 16-bit Metal & EDR'),text('16-bit 线性浮点 Metal EDR HDR AgX 对比中心 高光滚降 Guided Filter 溢出警示 曝光 白平衡 自动影调','16-bit extended linear Metal EDR HDR AgX pivot rolloff Guided Filter clipping J exposure white balance auto tone')],
    ['features.html#color',text('曲线、OKLCH 点颜色与参考图对色','Curves, OKLCH Point Color & Color Match'),text('RGB 曲线 OKLCH HSL 点颜色 吸管 参考图调色 反解参数 肤色保护 颜色分级 黑白 校准','RGB curves OKLCH HSL Point Color eyedropper Reference Color Match skin protection color grading B&W calibration')],
    ['features.html#film',text('胶片、AI 降噪超分与无痕消除','Film, AI Denoise / 2x Super Res & Remove'),text('303 HALD CLUT cube 颗粒粗糙度 暗角 光晕 YCoCg RAW 降噪 2x 超分 LaMa PatchMatch 修复 克隆 消除','303 HALD CLUT cube grain roughness vignette halation YCoCg RAW denoise 2x super resolution LaMa PatchMatch Heal Clone Remove')],
    ['features.html#masks',text('复合布尔蒙版与 AI 分割','Composite Boolean Masks & AI Segmentation'),text('加 减 交 布尔蒙版 自动边缘吸附 压感 8 部位人像 天空分割 Guided Filter 局部曲线 局部点颜色 抠图','Add Subtract Intersect boolean masks Auto Mask pen pressure 8 portrait parts sky segmentation Guided Filter local curve local Point Color cutout')],
    ['features.html#geometry',text('裁剪、镜头校正与单目深度散景','Crop, 82 Lens Profiles & Depth Optical Bokeh'),text('82 支内置镜头 Lensfun 自动透视 8 等分网格 单目深度 DepthAnythingV2 物理散景 多边形叶片 HDR 光斑 猫眼旋焦','82 lens profiles Lensfun auto perspective 8-grid monocular depth DepthAnythingV2 optical bokeh polygon blades HDR specular cat-eye')],
    ['features.html#workflow',text('多视图选片、智能挑片、搜图与 XMP','Multi-View, Smart Culling, Search & XMP'),text('网格 G 对比 C 多图 N 参考 ⇧R 智能挑片 闭眼 跑焦 连拍 双语语义搜图 相似图 虚拟副本 Adobe XMP LR 预设 200%','Grid G Compare C Survey N Reference Smart Culling eye closure sharpness burst bilingual semantic search similar virtual copies Adobe XMP Lightroom presets')],
    ['features.html#export',text('广色域 / HDR 导出与 2x 超分','HDR / Wide-Gamut Export & 2x Super Res'),text('Gain-Map HDR JPEG 10-bit PQ HEIC 16-bit Display P3 TIFF PNG 导出 2x 超分 EXIF IPTC 移除 GPS 水印','Gain-Map HDR JPEG 10-bit PQ HEIC 16-bit Display P3 TIFF PNG export 2x super resolution EXIF IPTC strip GPS watermark')],
    ['features.html#local-ai',text('零 Python 原生 AI 与 5 槽位模型中心','Zero-Python Native AI & 5-Slot Model Hub'),text('零 Python NativePhotoPlanner 参考图对色 Core ML 模型中心 LaMa Sky Depth Denoise SuperRes 可选 Qwen3-VL MLX','Zero-Python NativePhotoPlanner Color Match Core ML Model Hub LaMa Sky Depth Denoise SuperRes optional Qwen3-VL MLX')],
    ['features.html#native',text('原生 Metal 引擎、双语与文件兼容','Native Metal Engine, Bilingual & Files'),text('20 个 Metal 计算内核 Swift Core Image Vision 1017 条双语翻译 双向 XMP rawforge.json 旁档','20 Metal compute kernels Swift Core Image Vision 1017 bilingual strings bidirectional XMP rawforge.json sidecars')],
    ['help.html#install',text('安装与首次打开','Install & first launch'),text('macOS 公证 安全性 放行 Gatekeeper xattr','macOS notarization security allow Gatekeeper xattr')],
    ['help.html#download-help',text('下载渠道与校验','Mirrors & verification'),'DMG ZIP SHA256 GitHub Cloudflare jsDelivr'],
    ['help.html#ai-model',text('零 Python 原生 AI 与可选模型','Native AI & Optional Models'),text('模型中心 Core ML install_lama_model install_depth_model LaMa DepthAnythingV2 Python MLX Qwen3-VL hf-mirror','Model Hub Core ML install_lama_model install_depth_model LaMa DepthAnythingV2 Python MLX Qwen3-VL hf-mirror')],
    ['help.html#windows',text('Windows 实验版','Experimental Windows build'),'Windows 11 x64 SmartScreen'],
    ['index.html#motion-settings',text('网页动效设置','Website motion settings'),text('动画 减少动态 关闭 开启','Animation reduce disable enable')],
    ['index.html#ai-demos',text('端侧 AI 实测对比','On-device AI comparisons'),text('参考图调色 对色 单目深度 物理散景 无痕消除 LaMa PatchMatch 对比','Reference Color Match monocular depth optical bokeh Content-Aware Remove LaMa PatchMatch before after')],
    ['index.html#compare',text('Phos vs Lightroom 对比','Phos vs Lightroom comparison'),text('Lightroom Classic 对比 差异 订阅 价格 XMP 预设 免费替代','Lightroom Classic comparison differences subscription pricing XMP presets free alternative')],
    ['changelog.html',text('更新日志（v4.0 – v4.7.2）','Changelog (v4.0 – v4.7.2)'),text('版本 演进 历史 更新 记录 4.7.2 4.7.1 4.7.0 4.6.0 4.5.0','Release history versions updates notes 4.7.2 4.7.1 4.7.0 4.6.0 4.5.0')],
    ['index.html#faq',text('常见问题','Frequently asked questions'),text('价格 隐私 格式 Lightroom 对比 相机 系统要求 AI 模型','Price privacy formats Lightroom comparison camera requirements AI models')]
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
    found.forEach(([href,title,description])=>{const a=document.createElement('a');a.className='command-result';a.href=href;const left=document.createElement('div'),strong=document.createElement('strong'),small=document.createElement('small'),kind=document.createElement('span');strong.textContent=title;small.textContent=description;kind.textContent=href.startsWith('features')?text('功能','Feature'):href.startsWith('help')?text('帮助','Help'):href.startsWith('changelog')?text('日志','Changelog'):text('首页','Overview');left.append(strong,small);a.append(left,kind);a.addEventListener('click',()=>closeDialog(command));a.addEventListener('keydown',e=>{if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();const links=[...results.querySelectorAll('a')],i=links.indexOf(a);links[(i+(e.key==='ArrowDown'?1:links.length-1))%links.length].focus();}});results.append(a);});
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
    const frame=button.closest('.gallery-panel, .feature-shot, .workspace-figure, .bento-media'),image=frame&&(frame.querySelector('img.active')||frame.querySelector('img'));
    if(!image)return;
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
  nativeDialog.append(closeButton(nativeDialog));const nativeHeading=document.createElement('h2'),nativeCopy=document.createElement('p'),nativeLink=document.createElement('a');nativeHeading.textContent=text('在 Phos 中使用 AI 分割与复合蒙版。','Use AI segmentation and composite masks in Phos.');nativeCopy.textContent=text('主体、天空、8 部位人像、前景抠图与单目深度均在 Mac 上以 Vision / Metal / Core ML 本地完成，支持加/减/交布尔组合与 Guided Filter 边缘精修。网页仅保留交互入口示意。','Subject, sky, 8-part portrait, foreground cutout and monocular depth masks run locally on your Mac via Vision, Metal and Core ML, with Add/Subtract/Intersect boolean ops and Guided Filter edge refinement. This web entry is an overview only.');nativeLink.className='text-link';nativeLink.href='features.html#masks';nativeLink.textContent=text('查看复合蒙版与 AI 分割的完整说明','Read about composite masks & AI segmentation');nativeDialog.append(nativeHeading,nativeCopy,nativeLink);
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
  // Fast HiDPI RGB + Luminance smooth curve histogram (matches Phos native HistogramView).
  const hist=document.getElementById('hist'),histCanvas=document.getElementById('histCanvas'),status=document.getElementById('histStatus');
  const editorDisclosure=demo.closest('.try-editor');
  const tfRS=document.getElementById('tfRS'),tfSat=document.getElementById('tfSat'),tfSep=document.getElementById('tfSep'),tfHue=document.getElementById('tfHue'),tfCR=document.getElementById('tfCR');
  let histRaf=0,baseImageData=null,loadingPixels=false;
  function clamp01(v){return v<0?0:v>1?1:v;}
  function mul3(a,b){
    return [
      a[0]*b[0]+a[1]*b[3]+a[2]*b[6], a[0]*b[1]+a[1]*b[4]+a[2]*b[7], a[0]*b[2]+a[1]*b[5]+a[2]*b[8],
      a[3]*b[0]+a[4]*b[3]+a[5]*b[6], a[3]*b[1]+a[4]*b[4]+a[5]*b[7], a[3]*b[2]+a[4]*b[5]+a[5]*b[8],
      a[6]*b[0]+a[7]*b[3]+a[8]*b[6], a[6]*b[1]+a[7]*b[4]+a[8]*b[7], a[6]*b[2]+a[7]*b[5]+a[8]*b[8]
    ];
  }
  function smoothBins(arr){
    const n=arr.length,tmp=new Float32Array(n),out=new Float32Array(n);
    for(let i=0;i<n;i++) tmp[i]=(arr[Math.max(0,i-1)]*0.22)+(arr[i]*0.56)+(arr[Math.min(n-1,i+1)]*0.22);
    for(let i=0;i<n;i++) out[i]=(tmp[Math.max(0,i-1)]*0.22)+(tmp[i]*0.56)+(tmp[Math.min(n-1,i+1)]*0.22);
    return out;
  }
  function drawCurveChannel(ctx,bins,w,h,peak,fillStyle,strokeStyle){
    const n=bins.length,padTop=5;
    ctx.beginPath();
    ctx.moveTo(0,h);
    for(let i=0;i<n;i++){
      const x=(i/(n-1))*w;
      const norm=Math.min(1,Math.pow(bins[i]/peak,0.78));
      const y=h-norm*(h-padTop);
      if(i===0){ctx.lineTo(x,y);}else{
        const px=((i-1)/(n-1))*w;
        const pnorm=Math.min(1,Math.pow(bins[i-1]/peak,0.78));
        const py=h-pnorm*(h-padTop);
        ctx.quadraticCurveTo(px,py,(px+x)*0.5,(py+y)*0.5);
      }
    }
    const lastY=h-Math.min(1,Math.pow(bins[n-1]/peak,0.78))*(h-padTop);
    ctx.lineTo(w,lastY);
    ctx.lineTo(w,h);
    ctx.closePath();
    if(fillStyle){ctx.fillStyle=fillStyle;ctx.fill();}
    if(strokeStyle){
      ctx.beginPath();
      for(let i=0;i<n;i++){
        const x=(i/(n-1))*w;
        const y=h-Math.min(1,Math.pow(bins[i]/peak,0.78))*(h-padTop);
        if(i===0)ctx.moveTo(x,y);
        else{
          const px=((i-1)/(n-1))*w;
          const py=h-Math.min(1,Math.pow(bins[i-1]/peak,0.78))*(h-padTop);
          ctx.quadraticCurveTo(px,py,(px+x)*0.5,(py+y)*0.5);
        }
      }
      ctx.lineTo(w,lastY);
      ctx.strokeStyle=strokeStyle;
      ctx.lineWidth=1.1;
      ctx.stroke();
    }
  }
  function renderHistogram(){
    histRaf=0;
    if(!hist||!histCanvas)return;
    if(editorDisclosure&&!editorDisclosure.open)return;
    if(!baseImageData){
      if(!loadingPixels){
        loadingPixels=true;
        pixels().then(data=>{baseImageData=data;loadingPixels=false;scheduleHistogram();}).catch(()=>{loadingPixels=false;hist.dataset.state='unavailable';});
      }
      return;
    }
    const rect=hist.getBoundingClientRect();
    const w=Math.max(120,Math.round(rect.width)),h=Math.max(40,Math.round(rect.height));
    const dpr=Math.min(window.devicePixelRatio||1,2);
    if(histCanvas.width!==Math.round(w*dpr)||histCanvas.height!==Math.round(h*dpr)){
      histCanvas.width=Math.round(w*dpr);histCanvas.height=Math.round(h*dpr);
    }
    const ctx=histCanvas.getContext('2d');
    ctx.setTransform(dpr,0,0,dpr,0,0);
    ctx.clearRect(0,0,w,h);

    const slope=parseFloat(tfRS?.getAttribute('slope')||'1')||1;
    const inter=parseFloat(tfRS?.getAttribute('intercept')||'0')||0;
    const sat=parseFloat(tfSat?.getAttribute('values')||'1');
    const satV=Number.isFinite(sat)?sat:1;
    const sepRaw=(tfSep?.getAttribute('values')||'').trim().split(/\s+/).map(Number);
    const sepM=sepRaw.length>=15?[sepRaw[0],sepRaw[1],sepRaw[2],sepRaw[5],sepRaw[6],sepRaw[7],sepRaw[10],sepRaw[11],sepRaw[12]]:[1,0,0,0,1,0,0,0,1];
    const hueDeg=parseFloat(tfHue?.getAttribute('values')||'0')||0;
    const rad=hueDeg*Math.PI/180,co=Math.cos(rad),sn=Math.sin(rad);
    const satM=[
      0.213+0.787*satV, 0.715-0.715*satV, 0.072-0.072*satV,
      0.213-0.213*satV, 0.715+0.285*satV, 0.072-0.072*satV,
      0.213-0.213*satV, 0.715-0.715*satV, 0.072+0.928*satV
    ];
    const hueM=[
      0.213+co*0.787-sn*0.213, 0.715-co*0.715-sn*0.715, 0.072-co*0.072+sn*0.928,
      0.213-co*0.213+sn*0.143, 0.715+co*0.285+sn*0.140, 0.072-co*0.072-sn*0.283,
      0.213-co*0.213-sn*0.787, 0.715-co*0.715+sn*0.715, 0.072+co*0.928+sn*0.072
    ];
    const M=mul3(hueM,mul3(sepM,satM));

    const tbl=(tfCR?.getAttribute('tableValues')||'0 1').trim().split(/\s+/).map(Number);
    const tn=Math.max(2,tbl.length);
    const linLut=new Float32Array(256),curLut=new Float32Array(256);
    for(let i=0;i<256;i++){
      linLut[i]=clamp01((i/255)*slope+inter);
      const pos=(i/255)*(tn-1),idx=Math.min(tn-2,Math.floor(pos)),f=pos-idx;
      curLut[i]=clamp01(tbl[idx]+(tbl[idx+1]-tbl[idx])*f);
    }

    const BINS=64,rB=new Float32Array(BINS),gB=new Float32Array(BINS),bB=new Float32Array(BINS),lB=new Float32Array(BINS);
    const d=baseImageData.data,iw=baseImageData.width,ih=baseImageData.height;
    for(let y=0;y<ih;y+=2){
      const row=y*iw*4;
      for(let x=0;x<iw;x+=2){
        const ix=row+x*4;
        const r1=linLut[d[ix]],g1=linLut[d[ix+1]],b1=linLut[d[ix+2]];
        const r2=clamp01(M[0]*r1+M[1]*g1+M[2]*b1);
        const g2=clamp01(M[3]*r1+M[4]*g1+M[5]*b1);
        const b2=clamp01(M[6]*r1+M[7]*g1+M[8]*b1);
        const rf=curLut[(r2*255+0.5)|0],gf=curLut[(g2*255+0.5)|0],bf=curLut[(b2*255+0.5)|0];
        const lf=0.2126*rf+0.7152*gf+0.0722*bf;
        rB[Math.min(BINS-1,(rf*BINS)|0)]++;
        gB[Math.min(BINS-1,(gf*BINS)|0)]++;
        bB[Math.min(BINS-1,(bf*BINS)|0)]++;
        lB[Math.min(BINS-1,(lf*BINS)|0)]++;
      }
    }

    const sR=smoothBins(rB),sG=smoothBins(gB),sB=smoothBins(bB),sL=smoothBins(lB);
    let peak=1;
    for(let i=2;i<BINS-2;i++){
      if(sR[i]>peak)peak=sR[i];
      if(sG[i]>peak)peak=sG[i];
      if(sB[i]>peak)peak=sB[i];
      if(sL[i]>peak)peak=sL[i];
    }

    // Subtle quarter-stop exposure gridlines
    ctx.strokeStyle='rgba(255,255,255,0.06)';
    ctx.lineWidth=1;
    [0.25,0.5,0.75].forEach(p=>{
      const gx=Math.round(w*p)+0.5;
      ctx.beginPath();ctx.moveTo(gx,0);ctx.lineTo(gx,h);ctx.stroke();
    });

    ctx.globalCompositeOperation='screen';
    drawCurveChannel(ctx,sR,w,h,peak,'rgba(232,82,82,0.48)','rgba(246,118,118,0.82)');
    drawCurveChannel(ctx,sG,w,h,peak,'rgba(72,196,110,0.46)','rgba(112,224,144,0.82)');
    drawCurveChannel(ctx,sB,w,h,peak,'rgba(72,146,242,0.50)','rgba(116,178,250,0.84)');
    ctx.globalCompositeOperation='source-over';
    drawCurveChannel(ctx,sL,w,h,peak,null,'rgba(245,245,247,0.36)');

    hist.dataset.state='ready';
    if(status)status.textContent=text('实时 RGB 预览直方图已更新','Live RGB preview histogram updated');
  }
  function scheduleHistogram(){
    if(editorDisclosure&&!editorDisclosure.open)return;
    if(!histRaf)histRaf=requestAnimationFrame(renderHistogram);
  }
  editorDisclosure?.addEventListener('toggle',()=>{if(editorDisclosure.open)requestAnimationFrame(scheduleHistogram);});
  if(hist&&'ResizeObserver' in window)new ResizeObserver(scheduleHistogram).observe(hist);
  demo.addEventListener('phos:studio-render',scheduleHistogram);
  demo.addEventListener('input',scheduleHistogram);
  demo.addEventListener('click',scheduleHistogram);
  demo.addEventListener('pointerup',scheduleHistogram);
  demo.addEventListener('keydown',scheduleHistogram);
  scheduleHistogram();
})();
