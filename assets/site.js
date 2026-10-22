(function(){
  'use strict';

  /* ---------- 演示区里由脚本生成的文案 ----------
     按 <html lang> 选中文或英文；两份页面共用这一份脚本，
     所以文案集中放在这里，不在 HTML 里重复。 */
  var UI = (function(){
    var isZh = (document.documentElement.lang || 'zh').toLowerCase().indexOf('zh') === 0;
    return isZh ? {
      originalBadge: '原图 · 未调整',
      renderBadge: function(n, ms){
        return '第 ' + n + ' 次渲染 · ' + ms + 'ms · 4096 × 6144';
      },
      hints: {
        linear: '线性渐变工具已激活：<strong>直接拖动画面上的三个圆点</strong>——青色改范围，白色移中轴。参数只作用在选区内，和全局调整互不干扰。',
        radial: '径向渐变：在画布上拖出椭圆，再拖边缘改横纵半径、拖旋转柄改角度。羽化控制内外过渡，虚线内圈就是羽化边界。',
        brush:  '画笔：直接在画布上按住拖动涂抹，一次拖动算一笔。软边与笔刷大小随时可调，涂多了切橡皮擦擦回去。',
        range:  '颜色 / 亮度范围：在画布上点一下就把那一点的颜色或亮度收进来，容差决定范围宽窄，再配合下面的滑杆微调。',
        ai:     '选择主体 / 人物 / 主体抠图：全部由系统 Vision 模型在本机计算，不联网。第一次算要等一两秒，结果会缓存，不准可以重算。',
        depth:  '深度涂绘：把想虚化的背景涂白、要清晰的主体留黑，配合「焦外散景」强度使用；也可以直接读 iPhone 人像的深度数据。'
      }
    } : {
      originalBadge: 'Original · Unadjusted',
      renderBadge: function(n, ms){
        return 'Render ' + n + ' · ' + ms + 'ms · 4096 × 6144';
      },
      hints: {
        linear: 'Linear gradient tool active: <strong>drag the three dots on the canvas</strong> — cyan changes the range, white moves the axis. Settings apply only inside the mask, independent of global adjustments.',
        radial: 'Radial gradient: drag out an ellipse, then drag its edge to change the horizontal or vertical radius, or the rotation handle to rotate it. Feather controls the inner–outer transition; the dashed inner ellipse marks the feather boundary.',
        brush:  'Brush: hold and paint directly on the canvas — each drag is one stroke. Softness and brush size stay adjustable; switch to the eraser to paint back.',
        range:  'Color / luminance range: click anywhere on the canvas to sample that point; tolerance sets how wide the range is. Fine-tune it with the sliders below.',
        ai:     'Select Subject / Person / Cutout: all computed on-device by the system Vision models, with no network. The first run takes a second or two; results are cached and can be recomputed.',
        depth:  'Depth paint: paint the background white to blur it and the subject black to keep it sharp, then set the bokeh strength. iPhone portrait depth data can also be read directly.'
      }
    };
  })();

  /* ---------- 滚动入场 ---------- */
  var rv = document.querySelectorAll('.rv');
  var rvStagger = document.querySelectorAll('.rv-stagger');
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  if (!('IntersectionObserver' in window) || reduce) {
    rv.forEach(function(el){ el.classList.add('in'); });
    rvStagger.forEach(function(el){ el.classList.add('in'); });
  } else {
    var io = new IntersectionObserver(function(entries){
      entries.forEach(function(en){
        if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); }
      });
    }, {rootMargin:'0px 0px -12% 0px', threshold:.08});

    rv.forEach(function(el){ io.observe(el); });
    rvStagger.forEach(function(el){ io.observe(el); });
  }

  /* ---------- 导航栏滚动响应 ---------- */
  var nav = document.querySelector('.nav');
  var lastScroll = 0;
  window.addEventListener('scroll', function(){
    var scroll = window.pageYOffset;
    if (scroll > 80) nav.classList.add('scrolled');
    else nav.classList.remove('scrolled');

    // 更新滚动进度条
    var docHeight = document.documentElement.scrollHeight - window.innerHeight;
    var progress = (scroll / docHeight) * 100;
    document.documentElement.style.setProperty('--scroll-width', progress + '%');

    lastScroll = scroll;
  }, {passive:true});

  /* ---------- 数字滚动动画 ----------
     目标值、后缀与动画方式都从 data-* 读取（data-count / data-suffix / data-mode），
     不再靠匹配文本里的中文（如「种」）——中英两版共用同一份脚本。 */
  function statValue(el, n){
    return n + (el.getAttribute('data-suffix') || '');
  }
  function tweenStat(el, duration){
    var target = parseInt(el.getAttribute('data-count'), 10) || 0;
    var startTime = null;
    function easeOutExpo(t){ return t === 1 ? 1 : 1 - Math.pow(2, -10 * t); }
    function step(ts){
      if (!startTime) startTime = ts;
      var progress = Math.min((ts - startTime) / duration, 1);
      var eased = easeOutExpo(progress);
      el.textContent = statValue(el, Math.floor(eased * target));
      if (progress < 1) requestAnimationFrame(step);
      else el.textContent = statValue(el, target);
    }
    requestAnimationFrame(step);
  }
  function stepStat(el){
    var target = parseInt(el.getAttribute('data-count'), 10) || 64;
    var n = 0;
    var timer = setInterval(function(){
      n = Math.min(target, n + 4);
      if (n >= target) { clearInterval(timer); el.textContent = statValue(el, target); }
      else el.textContent = statValue(el, n);
    }, 30);
  }
  function typeStat(el){
    var chars = (el.getAttribute('data-text') || el.textContent.trim()).split('');
    var i = 0;
    el.textContent = '';
    var timer = setInterval(function(){
      if (i < chars.length) { el.textContent += chars[i]; i++; }
      else clearInterval(timer);
    }, 150);
  }
  function runStat(el){
    var mode = el.getAttribute('data-mode') || 'tween';
    if (mode === 'step') stepStat(el);
    else if (mode === 'type') typeStat(el);
    else tweenStat(el, 2000);
  }

  if (!reduce) {
    var statObserver = new IntersectionObserver(function(entries){
      entries.forEach(function(en){
        if (!en.isIntersecting) return;
        statObserver.unobserve(en.target);
        var b = en.target.querySelector('b');
        if (b) runStat(b);
      });
    }, {threshold: 0.5});

    document.querySelectorAll('.stat').forEach(function(el){
      /* 首屏下方的四个数字不在这里跑：它们要跟着下滑一起带出来，
         交给 .hero-reveal 的调度（见文末），否则页面一打开就先演完了 */
      if (el.closest('.hero-reveal')) return;
      statObserver.observe(el);
    });
  }

  /* =========================================================
     实时演示
     渲染顺序:影调 → 色彩 → 胶片 → 蒙版，与 Phos 一致
     ========================================================= */
  var stage = document.getElementById('stage');
  if (!stage) return;

  var S = { exp:14, con:18, hi:-22, sh:26, sat:8, tem:6, vib:16,
            film:'k2383', str:85, gr:22, vig:18, mExp:52, mFe:60 };

  var sceneGroup = document.getElementById('sceneGroup');
  var maskLayer  = document.getElementById('maskLayer');
  var guides     = document.getElementById('guides');
  var curveLine  = document.getElementById('curveLine');
  var curveSvg   = document.getElementById('curveSvg');
  var curvePtsG  = document.getElementById('curvePts');
  /* 影调滤镜 #toneFx 的各个基元。所有调整都写在这里，
     sceneGroup 上不再有 CSS filter，避免「外层滤镜缓存输入」的问题。 */
  var tf = {};
  ['tfRS','tfGS','tfBS','tfSat','tfSep','tfHue','tfCR','tfCG','tfCB'].forEach(function(id){
    tf[id] = document.getElementById(id);
  });
  function setNum(id, name, v){
    var el = tf[id];
    if (!el) return;
    var s = isFinite(v) ? (+v).toFixed(4) : '1';
    if (el.getAttribute(name) !== s) el.setAttribute(name, s);
  }
  function setStr(id, name, s){
    var el = tf[id];
    if (el && el.getAttribute(name) !== s) el.setAttribute(name, s);
  }
  function setCurveTable(str){
    setStr('tfCR','tableValues',str); setStr('tfCG','tableValues',str); setStr('tfCB','tableValues',str);
  }
  function resetTone(){                     // 全部回到中性（用于「原图」对比）
    setNum('tfRS','slope',1); setNum('tfRS','intercept',0);
    setNum('tfGS','slope',1); setNum('tfGS','intercept',0);
    setNum('tfBS','slope',1); setNum('tfBS','intercept',0);
    setNum('tfSat','values',1);
    setStr('tfSep','values','1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 1 0');
    setNum('tfHue','values',0);
    setCurveTable('0 1');
  }
  var grainLayer    = document.getElementById('grainLayer');
  var vignetteLayer = document.getElementById('vignetteLayer');
  var histBox    = document.getElementById('hist');
  var badgeText  = document.getElementById('badgeText');
  var shown      = 'after';

  /* ---------- 胶片预设 ----------
     每支胶片用一组数值参数描述，渲染时按「浓度」从 1 插值过去。
     旧版这里存的是整串 filter 字符串，但 render() 只用了浓度、没读这个字符串，
     导致三支胶片出来一模一样 —— 所以改成数值参数。 */
  var FILM = {
    none:  null,
    k2383: {sat:0.96, con:1.16, sep:0.20, hue: -9, bri:1.02}, // 暖调、对比强、略降饱和
    k2393: {sat:0.88, con:1.24, sep:0.30, hue:-16, bri:0.97}, // 更暖更浓、压暗部
    f3510: {sat:1.22, con:1.05, sep:0.02, hue: 11, bri:1.04}  // 偏冷青、高饱和、通透
  };

  /* ---------- 直方图 ---------- */
  var BARS = 34, barEls = [];
  for (var i = 0; i < BARS; i++) {
    var b = document.createElement('i');
    b.style.height = '2px';
    histBox.appendChild(b);
    barEls.push(b);
  }
  function drawHist(){
    // 用一条随参数移动的双峰分布模拟真实直方图
    var shift = (S.exp / 100) * 10 + (S.con / 100) * 3;
    var spread = 6 - (S.con / 100) * 2.4 + (S.sh / 100) * 1.2;
    var peakA = BARS * 0.34 + shift, peakB = BARS * 0.70 + shift * 0.7;
    var hA = 1 + (S.hi / 100) * 0.45, hB = 1 + (S.sh / 100) * 0.5;
    for (var k = 0; k < BARS; k++) {
      var gA = Math.exp(-Math.pow((k - peakA) / spread, 2)) * hA;
      var gB = Math.exp(-Math.pow((k - peakB) / (spread * 0.78), 2)) * hB;
      var v = Math.min(1, (gA * 0.92 + gB * 0.68) * (1 + (S.sat / 100) * 0.10));
      barEls[k].style.height = Math.max(2, Math.round(v * 56)) + 'px';
    }
  }

  /* ---------- 色调曲线 ----------
     曲线 = 手动控制点（可拖动） + 滑杆贡献（对比 / 高光 / 阴影 / 曝光）。
     两者叠加后同时用于「画出来」和「写进 feComponentTransfer 查找表」，
     所以看到的形状和画面实际变化是一致的。 */
  var CVN = 9;                              // 控制点个数
  var curvePts = [];                        // 手动曲线：9 个 y 值（0..1），初始为对角线
  for (var ci = 0; ci < CVN; ci++) curvePts.push(ci / (CVN - 1));

  function curveManual(t){                  // 手动曲线在 t 处的值（分段线性，与画面所画一致）
    var x = t * (CVN - 1), i = Math.floor(x), f = x - i;
    if (i >= CVN - 1) return curvePts[CVN - 1];
    return curvePts[i] + (curvePts[i + 1] - curvePts[i]) * f;
  }
  function curveSliders(t){                 // 滑杆对曲线的贡献
    var v = 0;
    v += (S.con / 100) * 0.55 * (t - 0.5) * (1 - Math.pow(2 * t - 1, 2));
    v += (S.hi / 100) * 0.16 * Math.pow(t, 2.4);
    v += (S.sh / 100) * 0.18 * Math.pow(1 - t, 2.4);
    v += (S.exp / 100) * 0.10;
    return v;
  }
  function curveTotal(t){
    return Math.max(0, Math.min(1, curveManual(t) + curveSliders(t)));
  }

  var CSTEP = 33;
  function drawCurve(){
    var pts = [];
    for (var x = 0; x <= CSTEP; x++) {
      var t = x / CSTEP;
      pts.push((t * 260).toFixed(1) + ',' + (110 - curveTotal(t) * 110).toFixed(1));
    }
    curveLine.setAttribute('points', pts.join(' '));

    // 控制点圆点
    if (curvePtsG) {
      while (curvePtsG.firstChild) curvePtsG.removeChild(curvePtsG.firstChild);
      for (var k = 0; k < CVN; k++) {
        var c = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        c.setAttribute('data-cpi', k);
        c.setAttribute('cx', ((k / (CVN - 1)) * 260).toFixed(1));
        c.setAttribute('cy', (110 - curveTotal(k / (CVN - 1)) * 110).toFixed(1));
        c.setAttribute('r', 4);
        c.style.cursor = 'ns-resize';
        curvePtsG.appendChild(c);
      }
    }

    // 写进查找表 —— 这一步才让曲线真正作用于画面
    var N = 17, tv = [];
    for (var m = 0; m < N; m++) tv.push(curveTotal(m / (N - 1)).toFixed(4));
    setCurveTable(tv.join(' '));
  }

  /* ---------- 画面 ---------- */
  var renderMs = 24;
  // 值没变就不写属性：颗粒层挂了 feTurbulence，无谓地改它会触发滤镜重算
  function setOpacityIfChanged(el, v){
    if (!el) return;
    var s = v.toFixed(3);
    if (el.getAttribute('opacity') !== s) el.setAttribute('opacity', s);
  }
  var renderCount = 0;
  function render(){
    var e = S.exp / 100, c = S.con / 100, s = S.sat / 100, vi = S.vib / 100, t = S.tem / 100;
    var strength = S.str / 100;

    if (shown === 'before') {
      resetTone();
      maskLayer.style.opacity = 0;
      setOpacityIfChanged(grainLayer, 0);
      setOpacityIfChanged(vignetteLayer, 0);
      renderCount++;
      badgeText.textContent = UI.originalBadge;
      return;
    }

    // ---- 基础调整 + 胶片，先合并成同类项（避免滤镜链过长）----
    var fm = FILM[S.film];
    var hasFilm = !!(fm && strength > 0.01);
    var fSat = hasFilm ? 1 + (fm.sat - 1) * strength : 1;
    var fCon = hasFilm ? 1 + (fm.con - 1) * strength : 1;
    var fBri = hasFilm ? 1 + (fm.bri - 1) * strength : 1;
    var fSep = hasFilm ? fm.sep * strength : 0;
    var fHue = hasFilm ? fm.hue * strength : 0;

    var vBri = (1 + e * 0.62) * fBri;
    var vCon = (1 + c * 0.55) * fCon;
    var vSat = Math.max(0, 1 + s * 0.85 + vi * 0.55) * fSat;
    // 色温与鲜艳度原先给得太弱（色温满量程只有 sepia .16 / hue -6°），
    // 拖到底几乎看不出变化，容易被误判成「滑杆坏了」，这里加到能明显感知
    var vSep = Math.min(1, Math.max(0, t * 0.30 + fSep));
    var vHue = -t * 14 + fHue;

    // 亮度 + 对比合成一个线性变换：out = b*(c*(in-0.5)+0.5)
    var slope = vBri * vCon;
    var inter = vBri * 0.5 * (1 - vCon);
    setNum('tfRS','slope',slope); setNum('tfRS','intercept',inter);
    setNum('tfGS','slope',slope); setNum('tfGS','intercept',inter);
    setNum('tfBS','slope',slope); setNum('tfBS','intercept',inter);

    setNum('tfSat','values',vSat);

    // sepia 矩阵按强度 a 向单位阵插值
    var a = vSep;
    setStr('tfSep','values', [
      1 - 0.607 * a, 0.769 * a,     0.189 * a,     0, 0,
      0.349 * a,     1 - 0.314 * a, 0.168 * a,     0, 0,
      0.272 * a,     0.534 * a,     1 - 0.869 * a, 0, 0,
      0,             0,             0,             1, 0
    ].map(function(x){ return (+x).toFixed(4); }).join(' '));

    setNum('tfHue','values',vHue);

    // 颗粒与暗角：后期层，直接改自身 opacity
    setOpacityIfChanged(grainLayer,    S.gr  / 100 * 0.42);
    setOpacityIfChanged(vignetteLayer, S.vig / 100 * 0.92);

    // 局部蒙版的曝光只在该蒙版被选中时叠加
    maskLayer.style.opacity = guidesOn() ? Math.max(0, S.mExp / 100 * 0.85).toFixed(3) : '0';

    renderCount++;
    badgeText.textContent = UI.renderBadge(renderCount, renderMs);
  }

  /* ---------- 控件绑定 ---------- */
  /* 拖动滑杆时 input 事件触发极密，每次都重建 9 个曲线控制点 + 重算直方图 + 重设滤镜
     会明显卡顿。用 rAF 合并成每帧一次。

     ⚠️ requestAnimationFrame 在页面不可见（切标签页 / 切窗口 / 被遮挡）时不会触发。
        只靠它的话，一次没执行到的回调就会让 rafPending 永久卡在 true，
        之后所有滑杆都不再渲染 —— 而且蒙版拖动走的是直接 render()，仍然正常，
        症状就成了「只有非蒙版功能偶发无响应」。
        所以必须加定时器兜底 + 回到前台补一帧。 */
  var rafPending = false, rafTimer = 0;
  function forceRender(){
    rafPending = false;
    if (rafTimer) { clearTimeout(rafTimer); rafTimer = 0; }
    // 即使直方图 / 曲线出错，也要保证画面本身渲染出来
    try { drawHist(); drawCurve(); } finally { render(); }
  }
  function flushRender(){ if (rafPending) forceRender(); }
  function scheduleRender(){
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(flushRender);
    rafTimer = setTimeout(flushRender, 120);   // rAF 不触发时的兜底
  }
  document.addEventListener('visibilitychange', function(){ if (!document.hidden) forceRender(); });

  function bind(id, key, out, fmt){
    var el = document.getElementById(id), o = document.getElementById(out);
    if (!el) return;
    function apply(){
      S[key] = +el.value;
      if (key === 'str') o.textContent = S.str + '%';
      else if (key === 'mFe') o.textContent = (S.mFe / 100).toFixed(2);
      else if (key === 'exp') o.textContent = (S.exp >= 0 ? '+' : '−') + Math.abs(S.exp / 100).toFixed(2);
      else o.textContent = (S[key] > 0 ? '+' : S[key] < 0 ? '−' : '') + Math.abs(Math.round(S[key]));
      // 停在「原图」时拖滑杆会自动切回「已调整」，否则用户会以为滑杆坏了
      if (shown === 'before') setCompareState('after');
      scheduleRender();
    }
    el.addEventListener('input', apply);
    apply();
  }
  bind('rExp','exp','oExp'); bind('rCon','con','oCon');
  bind('rHi','hi','oHi');    bind('rSh','sh','oSh');
  bind('rSat','sat','oSat'); bind('rTem','tem','oTem'); bind('rVib','vib','oVib');
  bind('rStr','str','oStr'); bind('rGr','gr','oGr');    bind('rVig','vig','oVig');
  bind('rMExp','mExp','oMExp'); bind('rMFe','mFe','oMFe');

  /* ---------- 曲线拖动 ---------- */
  if (curveSvg) {
    var cvDrag = -1, cvPid = -1;
    curveSvg.style.touchAction = 'none';
    curveSvg.style.cursor = 'crosshair';

    function cvLocal(ev){                 // 屏幕坐标 -> 曲线坐标
      var r = curveSvg.getBoundingClientRect();
      return {
        t: Math.max(0, Math.min(1, (ev.clientX - r.left) / (r.width || 1))),
        v: Math.max(0, Math.min(1, 1 - (ev.clientY - r.top) / (r.height || 1)))
      };
    }
    function cvApply(ev){
      // 让「总曲线」落在光标位置：手动值 = 目标值 - 滑杆贡献
      var p = cvLocal(ev);
      curvePts[cvDrag] = Math.max(0, Math.min(1, p.v - curveSliders(cvDrag / (CVN - 1))));
      scheduleRender();
    }
    function cvEnd(){
      if (cvPid >= 0 && curveSvg.releasePointerCapture && curveSvg.hasPointerCapture &&
          curveSvg.hasPointerCapture(cvPid)) {
        try { curveSvg.releasePointerCapture(cvPid); } catch (e) {}
      }
      cvDrag = -1; cvPid = -1;
    }
    curveSvg.addEventListener('pointerdown', function(ev){
      var p = cvLocal(ev);
      cvDrag = Math.round(p.t * (CVN - 1));
      cvPid = ev.pointerId;
      cvApply(ev);
      if (curveSvg.setPointerCapture) {
        try { curveSvg.setPointerCapture(cvPid); } catch (e) {}
      }
      ev.preventDefault();
    });
    curveSvg.addEventListener('pointermove', function(ev){
      if (cvDrag < 0) return;
      cvApply(ev);
      ev.preventDefault();
    });
    curveSvg.addEventListener('pointerup', cvEnd);
    curveSvg.addEventListener('pointercancel', cvEnd);
    // 兜底：指针在窗口外松开时可能收不到 pointerup。
    // 若指针捕获没释放，后续指针事件会全被 curveSvg 抢走，滑杆就点不动了。
    window.addEventListener('pointerup', cvEnd);
    window.addEventListener('blur', cvEnd);

    curveSvg.addEventListener('dblclick', function(){        // 双击复位
      for (var k = 0; k < CVN; k++) curvePts[k] = k / (CVN - 1);
      scheduleRender();
    });
  }

  /* ---------- 标签页 ---------- */
  var tabBtns = document.querySelectorAll('.panel .tabs button');
  tabBtns.forEach(function(btn){
    btn.addEventListener('click', function(){
      tabBtns.forEach(function(b){ b.setAttribute('aria-selected', String(b === btn)); });
      document.querySelectorAll('.pane').forEach(function(p){
        p.classList.toggle('on', p.id === btn.dataset.pane);
      });
      // 切到蒙版页时自动显示参考线
      if (btn.dataset.pane === 'p-mask') { setGuides(true); } else { setGuides(false); }
    });
  });

  /* ---------- 胶片 ---------- */
  var filmBtns = document.querySelectorAll('#films button');
  filmBtns.forEach(function(btn){
    btn.addEventListener('click', function(){
      S.film = btn.dataset.film;
      filmBtns.forEach(function(b){ b.setAttribute('aria-pressed', String(b === btn)); });
      render();
    });
  });

  /* ---------- 前后对比 ---------- */
  var bAfter = document.getElementById('btnAfter'), bBefore = document.getElementById('btnBefore');
  function setCompareState(which){          // 只改状态与按钮外观，不触发渲染
    shown = which;
    bAfter.setAttribute('aria-pressed', String(which === 'after'));
    bBefore.setAttribute('aria-pressed', String(which === 'before'));
  }
  // 「原图」时滤镜被重置成中性，切回「已调整」必须重画曲线才能恢复
  function setCompare(which){ setCompareState(which); drawCurve(); render(); }
  bAfter.addEventListener('click', function(){ spacePeek = false; setCompare('after'); });
  bBefore.addEventListener('click', function(){ spacePeek = false; setCompare('before'); });

  /* 按住空格临时看原图。
     ⚠️ 只靠 keyup 复位会卡死：切窗口 / 失焦 / 切标签页时 keyup 收不到，
        shown 会永远停在 'before'，表现就是「拖滑杆画面完全没反应」。
        所以额外用 blur 与 visibilitychange 兜底。 */
  var spaceDown = false, spacePeek = false;
  function endSpacePeek(){
    if (!spaceDown && !spacePeek) return;
    spaceDown = false;
    if (spacePeek) { spacePeek = false; setCompare('after'); }
  }
  window.addEventListener('keydown', function(ev){
    if (ev.code === 'Space' && !spaceDown && document.activeElement.tagName !== 'INPUT') {
      spaceDown = true; spacePeek = true; setCompare('before'); ev.preventDefault();
    }
  });
  window.addEventListener('keyup', function(ev){
    if (ev.code === 'Space') endSpacePeek();
  });
  window.addEventListener('blur', endSpacePeek);
  document.addEventListener('visibilitychange', function(){ if (document.hidden) endSpacePeek(); });

  /* =========================================================
     蒙版：线性 = 三条参考线；径向 = 椭圆 + 羽化内圈
     两组控制点都能直接拖，坐标统一在 1200×760 的画面空间里
     ========================================================= */
  var gA = document.getElementById('gA'), gB = document.getElementById('gB'), gC = document.getElementById('gC');
  var linearGuides = document.getElementById('linearGuides');
  var radialGuides = document.getElementById('radialGuides');
  var rOuter = document.getElementById('rOuter'), rInner = document.getElementById('rInner');
  var hStart = document.getElementById('hStart'), hEnd = document.getElementById('hEnd'),
      hMid = document.getElementById('hMid'), hRot = document.getElementById('hRot');
  var maskGrad = document.getElementById('maskGrad');
  var maskRadialGrad = document.getElementById('maskRadialGrad');

  var W = 1200, H = 760;
  var maskKind = 'linear';
  // 线性：归一化起止点
  var mS = {x:0.20, y:0.72}, mE = {x:0.78, y:0.24};
  // 径向：归一化圆心 + 像素半径 + 角度
  var rC = {x:0.46, y:0.46}, rRX = 300, rRY = 200, rAngle = -18;
  var ROT_OFF = 92, ROT_DIST = 34;

  function guidesOn(){ return guides.getAttribute('opacity') === '1'; }
  function setGuides(on){
    guides.setAttribute('opacity', on ? '1' : '0');
    maskLayer.style.opacity = on ? Math.max(0, S.mExp / 100 * 0.85).toFixed(3) : '0';
  }

  function rot(cx, cy, x, y, deg){
    var a = deg * Math.PI / 180, c = Math.cos(a), s = Math.sin(a);
    return { x: cx + x * c - y * s, y: cy + x * s + y * c };
  }

  function updateMask(){
    var radial = (maskKind === 'radial');
    linearGuides.style.display = radial ? 'none' : '';
    radialGuides.style.display = radial ? '' : 'none';
    maskLayer.setAttribute('fill', radial ? 'url(#maskRadialGrad)' : 'url(#maskGrad)');

    // 控制点配色与真机一致：线性为青/白/琥珀，径向为黄/黄/琥珀
    var edge = radial ? '#f5d94a' : '#3ad0e0';
    var midColor = radial ? '#f5d94a' : '#ffffff';
    [hStart, hEnd].forEach(function(el){
      el.setAttribute('fill', edge);
      el.setAttribute('r', radial ? 9.5 : 11);
    });
    hMid.setAttribute('fill', midColor);

    if (!radial) {
      var sx = mS.x * W, sy = mS.y * H, ex = mE.x * W, ey = mE.y * H;
      var mx = (sx + ex) / 2, my = (sy + ey) / 2;
      var dx = ex - sx, dy = ey - sy;
      var len = Math.max(Math.hypot(dx, dy), 1);
      var nx = -dy / len, ny = dx / len, L = 1500;

      function line(el, px, py){
        el.setAttribute('x1', px - nx * L); el.setAttribute('y1', py - ny * L);
        el.setAttribute('x2', px + nx * L); el.setAttribute('y2', py + ny * L);
      }
      line(gA, sx, sy); line(gB, mx, my); line(gC, ex, ey);

      hStart.setAttribute('cx', sx); hStart.setAttribute('cy', sy);
      hEnd.setAttribute('cx', ex);   hEnd.setAttribute('cy', ey);
      hMid.setAttribute('cx', mx);   hMid.setAttribute('cy', my);
      hRot.setAttribute('cx', mx + nx * ROT_OFF);
      hRot.setAttribute('cy', my + ny * ROT_OFF);

      maskGrad.setAttribute('x1', sx); maskGrad.setAttribute('y1', sy);
      maskGrad.setAttribute('x2', ex); maskGrad.setAttribute('y2', ey);
    } else {
      var cx = rC.x * W, cy = rC.y * H;
      var t = 'rotate(' + rAngle + ' ' + cx + ' ' + cy + ')';
      var inner = Math.max(0.05, 1 - S.mFe / 100);

      rOuter.setAttribute('cx', cx); rOuter.setAttribute('cy', cy);
      rOuter.setAttribute('rx', rRX); rOuter.setAttribute('ry', rRY);
      rOuter.setAttribute('transform', t);
      rInner.setAttribute('cx', cx); rInner.setAttribute('cy', cy);
      rInner.setAttribute('rx', rRX * inner); rInner.setAttribute('ry', rRY * inner);
      rInner.setAttribute('transform', t);

      var px = rot(cx, cy, rRX, 0, rAngle);
      var py = rot(cx, cy, 0, rRY, rAngle);
      var pr = rot(cx, cy, rRX + ROT_DIST, 0, rAngle);
      hMid.setAttribute('cx', cx);  hMid.setAttribute('cy', cy);
      hStart.setAttribute('cx', px.x); hStart.setAttribute('cy', px.y);
      hEnd.setAttribute('cx', py.x);   hEnd.setAttribute('cy', py.y);
      hRot.setAttribute('cx', pr.x);   hRot.setAttribute('cy', pr.y);

      maskRadialGrad.setAttribute('cx', cx);
      maskRadialGrad.setAttribute('cy', cy);
      maskRadialGrad.setAttribute('r', Math.max(rRX, rRY));
    }
  }

  // 屏幕坐标 → 画面像素坐标（svg 用 slice，按较长边换算）
  function toPix(ev){
    var r = stage.getBoundingClientRect();
    var scale = Math.max(r.width / W, r.height / H);
    var offX = (r.width - W * scale) / 2, offY = (r.height - H * scale) / 2;
    return { x: (ev.clientX - r.left - offX) / scale,
             y: (ev.clientY - r.top  - offY) / scale };
  }
  function clampN(v){ return Math.max(-0.2, Math.min(1.2, v)); }
  function clampR(v){ return Math.max(24, Math.min(1400, v)); }

  var drag = null;
  function startDrag(which){
    return function(ev){
      if (!guidesOn()) return;
      ev.preventDefault();
      drag = { which: which,
               s0: {x:mS.x, y:mS.y}, e0: {x:mE.x, y:mE.y},
               c0: {x:rC.x, y:rC.y}, rx0: rRX, ry0: rRY, ang0: rAngle,
               p0: toPix(ev) };
      if (stage.setPointerCapture) { try { stage.setPointerCapture(ev.pointerId); } catch(e){} }
    };
  }
  [[hStart,'s'],[hEnd,'e'],[hMid,'m'],[hRot,'r']].forEach(function(pair){
    pair[0].addEventListener('pointerdown', startDrag(pair[1]));
  });

  stage.addEventListener('pointermove', function(ev){
    if (!drag) return;
    var p = toPix(ev);

    if (maskKind === 'linear') {
      var dx = (p.x - drag.p0.x) / W, dy = (p.y - drag.p0.y) / H;
      if (drag.which === 'm') {
        mS = {x: clampN(drag.s0.x + dx), y: clampN(drag.s0.y + dy)};
        mE = {x: clampN(drag.e0.x + dx), y: clampN(drag.e0.y + dy)};
      } else if (drag.which === 's') {
        mS = {x: clampN(drag.s0.x + dx), y: clampN(drag.s0.y + dy)};
      } else if (drag.which === 'e') {
        mE = {x: clampN(drag.e0.x + dx), y: clampN(drag.e0.y + dy)};
      } else if (drag.which === 'r') {
        var lmx = (drag.s0.x + drag.e0.x) / 2 * W, lmy = (drag.s0.y + drag.e0.y) / 2 * H;
        var a0 = Math.atan2(drag.e0.y * H - drag.s0.y * H, drag.e0.x * W - drag.s0.x * W);
        var a1 = Math.atan2(p.y - lmy, p.x - lmx);
        var da = a1 - a0, c = Math.cos(da), s = Math.sin(da);
        function rr(pt){ var x = pt.x * W - lmx, y = pt.y * H - lmy;
          return { x: clampN((lmx + x * c - y * s) / W), y: clampN((lmy + x * s + y * c) / H) }; }
        mS = rr(drag.s0); mE = rr(drag.e0);
      }
    } else {
      var c0x = drag.c0.x * W, c0y = drag.c0.y * H;
      if (drag.which === 'm') {
        rC = { x: clampN(drag.c0.x + (p.x - drag.p0.x) / W),
               y: clampN(drag.c0.y + (p.y - drag.p0.y) / H) };
      } else if (drag.which === 's') {
        var lx = rot(0, 0, p.x - c0x, p.y - c0y, -drag.ang0);
        rRX = clampR(Math.abs(lx.x));
      } else if (drag.which === 'e') {
        var ly = rot(0, 0, p.x - c0x, p.y - c0y, -drag.ang0);
        rRY = clampR(Math.abs(ly.y));
      } else if (drag.which === 'r') {
        rAngle = drag.ang0 + (Math.atan2(p.y - c0y, p.x - c0x) -
                              Math.atan2(drag.p0.y - c0y, drag.p0.x - c0x)) * 180 / Math.PI;
      }
    }
    updateMask();
  });
  stage.addEventListener('pointerup', function(){ drag = null; });
  stage.addEventListener('pointercancel', function(){ drag = null; });

  /* ---------- 蒙版列表 ---------- */
  var maskRows = document.querySelectorAll('.maskrow');
  var maskHint = document.getElementById('maskHint');
  maskRows.forEach(function(row){
    function pick(){
      maskRows.forEach(function(r){ r.setAttribute('aria-pressed', String(r === row)); });
      var k = row.dataset.mask;
      maskHint.innerHTML = UI.hints[k] || '';
      var isMask = (k === 'linear' || k === 'radial');
      setGuides(isMask);
      if (k === 'linear') {
        maskKind = 'linear';
        mS = {x:0.20, y:0.72}; mE = {x:0.78, y:0.24};
      }
      if (k === 'radial') {
        maskKind = 'radial';
        rC = {x:0.46, y:0.46}; rRX = 300; rRY = 200; rAngle = -18;
      }
      updateMask(); render();
    }
    row.addEventListener('click', pick);
    row.addEventListener('keydown', function(ev){ if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); pick(); } });
  });

  /* ---------- 初始化 ---------- */
  updateMask();
  setGuides(true);
  drawHist();
  drawCurve();
  render();
  window.addEventListener('resize', updateMask);

  /* ---------- 首屏下方的截图与数字：下滑才带出来 ----------
     原先截图固定在加载后 .7s、数字 .85s 起播，页面一打开就演完了，
     用户滚下去看到的是已经演完的静态结果。现在统一由 .hero-reveal 进入视口触发：
     截图 scaleIn，四个数字沿用原来的滚动动画与 100ms 错峰，
     延迟与 CSS 上浮动画的 delay 对齐（.35s 起，逐个 +100ms）。 */
  var heroReveal = document.querySelector('.hero-reveal');
  if (heroReveal) {
    var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (!('IntersectionObserver' in window) || reduceMotion) {
      heroReveal.classList.add('in');
    } else {
      var heroIO = new IntersectionObserver(function(entries){
        entries.forEach(function(en){
          if (!en.isIntersecting) return;
          heroIO.unobserve(en.target);
          en.target.classList.add('in');
          var heroStats = en.target.querySelectorAll('.stat b');
          for (var hi = 0; hi < heroStats.length; hi++) {
            (function(el, i){
              setTimeout(function(){ runStat(el); }, 350 + i * 100);
            })(heroStats[hi], hi);
          }
        });
      }, {threshold:.15});
      heroIO.observe(heroReveal);
    }
  }

  /* ---------- 卡片悬停：柔和放大（原来这里是 3D 倾斜，
       倾斜会把子元素带进 3D 空间，文字容易被卡片背景压住，
       已改为纯 CSS 的呼吸式放大，见 .tile:hover / .feat:hover）---------- */

  /* ---------- 界面演示：图片加载完成后淡入 ----------
     懒加载的图如果直接出现会“啪”一下，很生硬。
     失败也要显示，别把位置留白。 */
  var galShots = document.querySelectorAll('.gal .shot');
  for (var gi = 0; gi < galShots.length; gi++) {
    (function(img){
      function show(){ img.classList.add('is-loaded'); }
      if (img.complete && img.naturalWidth) show();
      else {
        img.addEventListener('load',  show, {once:true});
        img.addEventListener('error', show, {once:true});
      }
    })(galShots[gi]);
  }

  /* ---------- 滚动动效 ----------
     原先有三个独立的 scroll 监听，而且每滚一帧就对每张 .shot 调一次
     getBoundingClientRect() —— 强制同步重排，滚动发涩。
     现在合并成一个，用 rAF 节流。 */
  var heroWrap = document.querySelector('.hero .wrap');
  var scrollTick = false;

  function onScrollFrame(){
    scrollTick = false;
    var y = window.pageYOffset, vh = window.innerHeight;

    if (reduce) {                     // 关掉动效时清掉可能残留的内联样式
      if (heroWrap) { heroWrap.style.transform = ''; heroWrap.style.opacity = ''; }
      return;
    }

    // Hero：轻微下移 + 淡出，但保留下限，不要整块消失
    if (heroWrap) {
      var p = Math.min(y / vh, 1);
      heroWrap.style.transform = 'translateY(' + (y * 0.15).toFixed(1) + 'px)';
      heroWrap.style.opacity = (1 - p * 0.55).toFixed(3);
    }

    /* 画廊图片的视差已移除：
       它按 (视口高 - 图片顶部) × 0.03 下移图片，最多能移 27px，
       而图注只有 24px 的上边距 —— 图片会盖住下面的文字。
       而且图片与图注错位本身也不合理，图注应该跟着图走。 */
  }
  function requestScrollFrame(){
    if (scrollTick) return;
    scrollTick = true;
    requestAnimationFrame(onScrollFrame);
  }
  window.addEventListener('scroll', requestScrollFrame, {passive:true});
  window.addEventListener('resize', requestScrollFrame, {passive:true});
  requestScrollFrame();

})();
