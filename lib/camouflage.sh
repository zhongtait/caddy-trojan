#!/bin/bash
# EasyTrojan module: camouflage.sh
# shellcheck shell=bash

write_camouflage_site() {
    mkdir -p "$WWW_DIR"
    if ! check_cmd unzip; then
        info "Installing unzip (needed for IT-Tools package)..."
        if check_cmd dnf; then dnf install -y unzip &>/dev/null || true
        elif check_cmd yum; then yum install -y unzip &>/dev/null || true
        elif check_cmd apt-get; then
            apt-get update -qq &>/dev/null || true
            apt-get install -y unzip &>/dev/null || true
        fi
    fi
    check_cmd curl || install_pkg curl

    local version="${IT_TOOLS_VERSION:-latest}"
    local api_url asset_url tmp_dir zip_path tag name extract_root
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    info "Installing camouflage site: IT-Tools (${version})..."

    if [ "$version" = "latest" ]; then
        api_url="https://api.github.com/repos/${IT_TOOLS_REPO}/releases/latest"
    else
        # accept v2024... or 2024...
        case "$version" in
            v*) tag="$version" ;;
            *) tag="v${version}" ;;
        esac
        api_url="https://api.github.com/repos/${IT_TOOLS_REPO}/releases/tags/${tag}"
    fi

    if ! check_cmd unzip; then
        warn "unzip not available; using built-in fallback tools page"
        write_camouflage_fallback
        trap - RETURN
        rm -rf "$tmp_dir"
        return 0
    fi

    # Resolve zip asset URL from GitHub API (fallback to known latest pattern if API blocked)
    asset_url=""
    if curl -fsSL --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: easytrojan" \
        "$api_url" -o "${tmp_dir}/release.json" 2>/dev/null; then
        asset_url=$(python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1],encoding="utf-8"))
  for a in d.get("assets") or []:
    n=a.get("name") or ""
    if n.endswith(".zip") and "it-tools" in n:
      print(a.get("browser_download_url",""))
      break
except Exception:
  pass
' "${tmp_dir}/release.json" 2>/dev/null || true)
        if [ -z "$asset_url" ]; then
            asset_url=$(grep -oE 'https://github.com/[^"]+it-tools[^"]+\.zip' "${tmp_dir}/release.json" 2>/dev/null | head -1 || true)
        fi
        tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("tag_name",""))' "${tmp_dir}/release.json" 2>/dev/null || true)
    fi

    if [ -z "$asset_url" ]; then
        # Last-known public release zip (updated when project bumps default)
        asset_url="https://github.com/CorentinTh/it-tools/releases/download/v2024.10.22-7ca5933/it-tools-2024.10.22-7ca5933.zip"
        tag="v2024.10.22-7ca5933"
        warn "GitHub API unavailable; using pinned IT-Tools release ${tag}"
    fi

    zip_path="${tmp_dir}/it-tools.zip"
    if ! curl -fsSL --connect-timeout 15 --max-time 300 -L \
        -H "User-Agent: easytrojan" \
        "$asset_url" -o "$zip_path"; then
        warn "Failed to download IT-Tools zip; using built-in fallback tools page"
        write_camouflage_fallback
        trap - RETURN
        rm -rf "$tmp_dir"
        return 0
    fi

    # Clear previous site (keep dir)
    find "$WWW_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    mkdir -p "${tmp_dir}/extract"
    if ! unzip -q "$zip_path" -d "${tmp_dir}/extract"; then
        warn "Failed to unzip IT-Tools; using built-in fallback tools page"
        write_camouflage_fallback
        trap - RETURN
        rm -rf "$tmp_dir"
        return 0
    fi

    # Zip may be flat (index.html at root) or nested in one folder
    if [ -f "${tmp_dir}/extract/index.html" ]; then
        extract_root="${tmp_dir}/extract"
    else
        local idx_html
        idx_html=$(find "${tmp_dir}/extract" -mindepth 1 -maxdepth 4 -type f -name index.html 2>/dev/null | head -1 || true)
        extract_root=$(dirname "$idx_html" 2>/dev/null || true)
    fi
    if [ -z "${extract_root:-}" ] || [ ! -f "${extract_root}/index.html" ]; then
        warn "IT-Tools archive layout unexpected; using fallback tools page"
        write_camouflage_fallback
        trap - RETURN
        rm -rf "$tmp_dir"
        return 0
    fi

    cp -a "${extract_root}/." "$WWW_DIR/"
    # Attribution for operators
    cat > "${WWW_DIR}/.it-tools-source.txt" <<EOF
source=https://github.com/${IT_TOOLS_REPO}
tag=${tag:-$version}
license=GPL-3.0
homepage=https://it-tools.tech
installed_by=easytrojan
EOF

    chown -R caddy:caddy "$WWW_DIR" 2>/dev/null || true
    find "$WWW_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$WWW_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
    ok "IT-Tools site installed to ${WWW_DIR} (${tag:-$version})"
    trap - RETURN
    rm -rf "$tmp_dir"
}

# Minimal offline SPA if GitHub download fails (still looks like a real tools site)
write_camouflage_fallback() {
    mkdir -p "${WWW_DIR}/assets"
    find "$WWW_DIR" -mindepth 1 -maxdepth 1 ! -name assets -exec rm -rf {} + 2>/dev/null || true
    cat > "${WWW_DIR}/assets/app.css" <<'EOF'
:root { --bg:#0b1220; --panel:#121a2b; --line:#243047; --text:#e8eefc; --muted:#93a0b8; --accent:#5b9dff; --ok:#3dd68c; --sans:ui-sans-serif,system-ui,sans-serif; --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
* { box-sizing:border-box; } body { margin:0; font-family:var(--sans); background:radial-gradient(1000px 500px at 10% -10%,#172554 0%,transparent 50%),var(--bg); color:var(--text); min-height:100vh; }
a { color:var(--accent); text-decoration:none; } .layout { display:grid; grid-template-columns:260px 1fr; min-height:100vh; }
@media (max-width:860px){ .layout{grid-template-columns:1fr;} .sidebar{position:sticky;top:0;z-index:5;} }
.sidebar { border-right:1px solid var(--line); background:rgba(18,26,43,.92); backdrop-filter:blur(8px); padding:1rem; }
.brand { font-weight:700; letter-spacing:.02em; margin-bottom:.25rem; } .brand small { display:block; color:var(--muted); font-weight:500; font-size:.78rem; margin-top:.2rem; }
.search { width:100%; margin:1rem 0; padding:.65rem .75rem; border-radius:10px; border:1px solid var(--line); background:#0d1526; color:var(--text); }
.nav { display:flex; flex-direction:column; gap:.25rem; max-height:70vh; overflow:auto; }
.nav button { text-align:left; border:0; background:transparent; color:var(--muted); padding:.55rem .65rem; border-radius:8px; cursor:pointer; font:inherit; }
.nav button:hover,.nav button.active { background:#1a2740; color:var(--text); }
.main { padding:1.25rem 1.4rem 2rem; } .panel { background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:1rem 1.1rem; }
h1 { font-size:1.35rem; margin:0 0 .35rem; } .desc { color:var(--muted); margin:0 0 1rem; font-size:.95rem; }
textarea,input,select { width:100%; border:1px solid var(--line); background:#0d1526; color:var(--text); border-radius:10px; padding:.7rem .8rem; font:inherit; }
textarea { min-height:140px; font-family:var(--mono); font-size:.9rem; resize:vertical; }
.row { display:flex; flex-wrap:wrap; gap:.6rem; margin:.75rem 0; }
button.act { border:0; border-radius:10px; background:var(--accent); color:#041018; font-weight:700; padding:.55rem .9rem; cursor:pointer; }
button.ghost { border:1px solid var(--line); background:transparent; color:var(--text); border-radius:10px; padding:.55rem .9rem; cursor:pointer; }
.out { margin-top:.8rem; white-space:pre-wrap; word-break:break-word; font-family:var(--mono); font-size:.88rem; background:#0d1526; border:1px solid var(--line); border-radius:10px; padding:.8rem; min-height:3rem; }
.muted { color:var(--muted); font-size:.85rem; }
EOF
    cat > "${WWW_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ByteDeck — developer utilities</title>
  <meta name="description" content="Collection of handy online tools for developers: Base64, Hash, JSON, UUID, URL encode, and more.">
  <meta name="theme-color" content="#0b1220">
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body>
  <div class="layout">
    <aside class="sidebar">
      <div class="brand">ByteDeck <small>developer utilities</small></div>
      <input class="search" id="filter" type="search" placeholder="Search tools..." aria-label="Search tools">
      <nav class="nav" id="nav" aria-label="Tools"></nav>
      <p class="muted" style="margin-top:1rem;">Offline fallback UI. Prefer full IT-Tools when network allows.</p>
    </aside>
    <main class="main">
      <section class="panel" id="app"></section>
    </main>
  </div>
  <script>
  const tools = [
    { id:'base64', name:'Base64 encode / decode', cat:'Conversion', run(ui){
      ui.desc('Encode or decode Base64 text in the browser.');
      ui.area('input','Text');
      ui.row([ui.btn('Encode',()=>ui.set(btoa(unescape(encodeURIComponent(ui.val('input')))))), ui.btn('Decode',()=>{try{ui.set(decodeURIComponent(escape(atob(ui.val('input')))))}catch(e){ui.set('Invalid Base64')}},'ghost')]);
      ui.out();
    }},
    { id:'url', name:'URL encode / decode', cat:'Conversion', run(ui){
      ui.desc('Percent-encoding helpers for query strings and paths.');
      ui.area('input','Text');
      ui.row([ui.btn('Encode',()=>ui.set(encodeURIComponent(ui.val('input')))), ui.btn('Decode',()=>{try{ui.set(decodeURIComponent(ui.val('input')))}catch(e){ui.set('Invalid input')}},'ghost')]);
      ui.out();
    }},
    { id:'hash', name:'SHA-256 hash', cat:'Crypto', run(ui){
      ui.desc('Compute SHA-256 using Web Crypto (local only).');
      ui.area('input','Text');
      ui.row([ui.btn('Hash', async ()=>{
        const data=new TextEncoder().encode(ui.val('input'));
        const buf=await crypto.subtle.digest('SHA-256', data);
        ui.set([...new Uint8Array(buf)].map(b=>b.toString(16).padStart(2,'0')).join(''));
      })]);
      ui.out();
    }},
    { id:'uuid', name:'UUID generator', cat:'Generators', run(ui){
      ui.desc('Generate RFC 4122 version 4 UUIDs.');
      ui.row([ui.btn('Generate',()=>ui.set(crypto.randomUUID())), ui.btn('Generate ×5',()=>ui.set(Array.from({length:5},()=>crypto.randomUUID()).join('\\n')),'ghost')]);
      ui.out();
    }},
    { id:'json', name:'JSON formatter', cat:'Development', run(ui){
      ui.desc('Pretty-print or minify JSON.');
      ui.area('input','JSON');
      ui.row([ui.btn('Pretty',()=>{try{ui.set(JSON.stringify(JSON.parse(ui.val('input')),null,2))}catch(e){ui.set(String(e))}}), ui.btn('Minify',()=>{try{ui.set(JSON.stringify(JSON.parse(ui.val('input'))))}catch(e){ui.set(String(e))}},'ghost')]);
      ui.out();
    }},
    { id:'jwt', name:'JWT decoder', cat:'Development', run(ui){
      ui.desc('Decode JWT header and payload (no signature verify).');
      ui.area('input','JWT');
      ui.row([ui.btn('Decode',()=>{
        try{
          const p=ui.val('input').trim().split('.');
          if(p.length<2) throw new Error('Not a JWT');
          const dec=s=>JSON.stringify(JSON.parse(atob(s.replace(/-/g,'+').replace(/_/g,'/'))),null,2);
          ui.set('Header\\n'+dec(p[0])+'\\n\\nPayload\\n'+dec(p[1]));
        }catch(e){ui.set(String(e))}
      })]);
      ui.out();
    }},
    { id:'timestamp', name:'Unix timestamp', cat:'Datetime', run(ui){
      ui.desc('Convert between Unix time and local datetime.');
      ui.input('ts','Unix seconds', String(Math.floor(Date.now()/1000)));
      ui.row([ui.btn('To date',()=>ui.set(new Date(Number(ui.val('ts'))*1000).toString())), ui.btn('Now',()=>{const n=Math.floor(Date.now()/1000); document.getElementById('ts').value=n; ui.set(String(n));},'ghost')]);
      ui.out();
    }},
    { id:'lorem', name:'Lorem text', cat:'Text', run(ui){
      ui.desc('Quick placeholder paragraphs.');
      const words='lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'.split(' ');
      ui.row([ui.btn('3 paragraphs',()=>{
        const para=()=>Array.from({length:40},()=>words[Math.floor(Math.random()*words.length)]).join(' ');
        ui.set([para(),para(),para()].map(p=>p[0].toUpperCase()+p.slice(1)+'.').join('\\n\\n'));
      })]);
      ui.out();
    }}
  ];
  const app=document.getElementById('app');
  const nav=document.getElementById('nav');
  const filter=document.getElementById('filter');
  function uiFactory(){
    const api={
      desc(t){const p=document.createElement('p');p.className='desc';p.textContent=t;app.appendChild(p)},
      area(id,label){const l=document.createElement('div');l.className='muted';l.textContent=label;app.appendChild(l);const t=document.createElement('textarea');t.id=id;app.appendChild(t)},
      input(id,label,v=''){const l=document.createElement('div');l.className='muted';l.textContent=label;app.appendChild(l);const i=document.createElement('input');i.id=id;i.value=v;app.appendChild(i)},
      row(nodes){const d=document.createElement('div');d.className='row';nodes.forEach(n=>d.appendChild(n));app.appendChild(d)},
      btn(label,fn,cls='act'){const b=document.createElement('button');b.type='button';b.className=cls;b.textContent=label;b.onclick=fn;return b},
      out(){const o=document.createElement('div');o.className='out';o.id='out';app.appendChild(o)},
      val(id){return document.getElementById(id).value},
      set(v){document.getElementById('out').textContent=v}
    }; return api;
  }
  function renderList(){
    const q=filter.value.trim().toLowerCase();
    nav.innerHTML='';
    tools.filter(t=>!q||t.name.toLowerCase().includes(q)||t.cat.toLowerCase().includes(q)).forEach(t=>{
      const b=document.createElement('button'); b.type='button'; b.dataset.id=t.id; b.textContent=t.name;
      b.onclick=()=>openTool(t.id); nav.appendChild(b);
    });
  }
  function openTool(id){
    const t=tools.find(x=>x.id===id)||tools[0];
    [...nav.querySelectorAll('button')].forEach(b=>b.classList.toggle('active',b.dataset.id===t.id));
    app.innerHTML='';
    const h=document.createElement('h1'); h.textContent=t.name; app.appendChild(h);
    const c=document.createElement('div'); c.className='muted'; c.style.marginBottom='.8rem'; c.textContent=t.cat; app.appendChild(c);
    t.run(uiFactory());
    history.replaceState(null,'','#'+t.id);
  }
  filter.addEventListener('input', renderList);
  renderList();
  openTool((location.hash||'#base64').slice(1));
  </script>
</body>
</html>
EOF
    chown -R caddy:caddy "$WWW_DIR" 2>/dev/null || true
    find "$WWW_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$WWW_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
    ok "Fallback tools site written to ${WWW_DIR}"
}
