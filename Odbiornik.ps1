# Odbiornik plików w sieci LAN.
# Uruchom na swoim PC (przez Odbiornik.bat). Na drugim PC otwórz w przeglądarce http://mdrop
# Nazwa jest ogłaszana w sieci (LLMNR + mDNS) tylko wtedy, gdy program działa.
param([string]$Name = 'mdrop', [int]$Port = 80, [int]$FallbackPort = 8765)

$ErrorActionPreference = 'Stop'
$Dir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Odebrane'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

try {
    Remove-NetFirewallRule -DisplayName 'Odbiornik plikow*' -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'Odbiornik plikow' -Direction Inbound -Protocol TCP -LocalPort $Port, $FallbackPort -Action Allow -Profile Any | Out-Null
    New-NetFirewallRule -DisplayName 'Odbiornik plikow (nazwa)' -Direction Inbound -Protocol UDP -LocalPort 5353, 5355 -Action Allow -Profile Any | Out-Null
} catch { Write-Host "Nie udało się dodać reguły zapory (brak uprawnień admina?)" -ForegroundColor Yellow }

# Odpowiada na pytania "kto to jest mdrop?" (LLMNR, port 5355) i "mdrop.local" (mDNS, port 5353)
$NameResponder = {
    param([string]$Name)
    function New-Udp([int]$port, [string]$group) {
        $u = New-Object System.Net.Sockets.UdpClient
        $u.Client.SetSocketOption('Socket', 'ReuseAddress', $true)
        $u.Client.Bind((New-Object System.Net.IPEndPoint ([Net.IPAddress]::Any), $port))
        $u.JoinMulticastGroup([Net.IPAddress]::Parse($group))
        $u
    }
    function Read-Name([byte[]]$b, [ref]$pos) {
        $labels = @(); $i = $pos.Value
        while ($i -lt $b.Length -and $b[$i] -ne 0) {
            if ($b[$i] -ge 0xC0) { return $null }
            $len = $b[$i]; $labels += [Text.Encoding]::ASCII.GetString($b, $i + 1, $len); $i += $len + 1
        }
        $pos.Value = $i + 1
        $labels -join '.'
    }
    # Adres IP tego komputera widziany od strony pytającego (ważne przy kilku kartach sieciowych)
    function Get-LocalIpFor([Net.IPAddress]$remote) {
        $s = New-Object System.Net.Sockets.Socket 'InterNetwork', 'Dgram', 'Udp'
        try { $s.Connect($remote, 9); $s.LocalEndPoint.Address.GetAddressBytes() } finally { $s.Close() }
    }
    function Build-Answer([byte[]]$q, [int]$qEnd, [int]$flags, [byte[]]$ip) {
        $ms = New-Object IO.MemoryStream
        $hdr = [byte[]]@($q[0], $q[1], ($flags -shr 8), ($flags -band 255), 0, 1, 0, $(if ($ip) { 1 } else { 0 }), 0, 0, 0, 0)
        $ms.Write($hdr, 0, $hdr.Length)
        $ms.Write($q, 12, $qEnd - 12)
        if ($ip) {
            $ans = [byte[]](@(0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4) + $ip)
            $ms.Write($ans, 0, $ans.Length)
        }
        $ms.ToArray()
    }

    $socks = @()
    try { $socks += , @((New-Udp 5355 '224.0.0.252'), $Name, $true) } catch { }
    try { $socks += , @((New-Udp 5353 '224.0.0.251'), "$Name.local", $false) } catch { }
    while ($true) {
        foreach ($s in $socks) {
            $u = $s[0]
            while ($u.Available -gt 0) {
                try {
                    $ep = New-Object System.Net.IPEndPoint ([Net.IPAddress]::Any), 0
                    $b = $u.Receive([ref]$ep)
                    if ($b.Length -lt 17 -or ($b[2] -band 0x80)) { continue }
                    $pos = 12; $qn = Read-Name $b ([ref]$pos)
                    if ($qn -ne $s[1] -or $pos + 4 -gt $b.Length) { continue }
                    $type = $b[$pos] * 256 + $b[$pos + 1]
                    if ($type -ne 1 -and $type -ne 28 -and $type -ne 255) { continue }
                    $ip = if ($type -ne 28) { Get-LocalIpFor $ep.Address } else { $null }
                    if ($s[2]) {
                        $r = Build-Answer $b ($pos + 4) 0x8000 $ip
                    } else {
                        if (-not $ip) { continue }
                        $r = Build-Answer $b ($pos + 4) 0x8400 $ip
                        if ($ep.Port -eq 5353) { $ep = New-Object System.Net.IPEndPoint ([Net.IPAddress]::Parse('224.0.0.251')), 5353 }
                    }
                    [void]$u.Send($r, $r.Length, $ep)
                } catch { }
            }
        }
        Start-Sleep -Milliseconds 30
    }
}

$Html = @'
<!doctype html>
<html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Odbiornik plików</title>
<style>
:root{--bg:#f4f5f7;--card:#fff;--fg:#1d2330;--mut:#6b7280;--acc:#2563eb;--ok:#16a34a;--err:#dc2626;--line:#e5e7eb}
@media (prefers-color-scheme:dark){:root{--bg:#14161b;--card:#1d2027;--fg:#e8eaee;--mut:#9aa1ad;--line:#2c3039}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,Segoe UI,sans-serif}
main{max-width:860px;margin:0 auto;padding:24px 16px}h1{font-size:22px;margin:0 0 16px}h2{font-size:16px;margin:24px 0 8px}
#drop{border:2px dashed var(--line);border-radius:14px;background:var(--card);padding:40px 16px;text-align:center;cursor:pointer;transition:.15s}
#drop.over{border-color:var(--acc);background:color-mix(in srgb,var(--acc) 8%,var(--card))}
#drop b{font-size:18px}#drop p{color:var(--mut);margin:6px 0 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}
.row{display:flex;gap:10px;align-items:center;padding:6px 0;border-bottom:1px solid var(--line)}.row:last-child{border:0}
.row .n{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.row .s{color:var(--mut);font-variant-numeric:tabular-nums;white-space:nowrap}
progress{width:140px}.ok{color:var(--ok)}.err{color:var(--err)}a{color:var(--acc);text-decoration:none}
textarea{width:100%;min-height:80px;background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:10px;padding:10px;font:inherit}
button{background:var(--acc);color:#fff;border:0;border-radius:8px;padding:8px 16px;font:inherit;cursor:pointer;margin-top:8px}
.empty{color:var(--mut)}
button.sec{background:transparent;color:var(--acc);border:1px solid var(--line)}
.note{border-bottom:1px solid var(--line);padding:8px 0}.note:last-child{border:0}
.note pre{margin:0;padding:10px;background:var(--bg);border-radius:8px;white-space:pre-wrap;word-break:break-all;font:13px/1.45 Consolas,ui-monospace,monospace;max-height:240px;overflow:auto}
.note .bar{display:flex;gap:8px;align-items:center;margin-top:4px}.note .bar .s{flex:1;color:var(--mut);font-size:13px}
.note button{margin:0;padding:4px 12px;font-size:13px}
</style></head><body><main>
<h1>📡 Odbiornik plików</h1>
<div id="drop"><b>Przeciągnij pliki tutaj</b><p>albo kliknij, żeby wybrać</p><input id="pick" type="file" multiple hidden></div>
<div id="up" class="card" style="margin-top:12px;display:none"></div>
<h2>Notatki</h2>
<textarea id="txt" placeholder="Wklej tekst (np. komendę, numer seryjny, log)…"></textarea>
<button id="saveNote">Zapisz notatkę</button> <button id="sendTxt" class="sec">Wyślij jako plik .txt</button>
<div id="notes" class="card" style="margin-top:12px"><span class="empty">Ładowanie…</span></div>
<h2>Pliki na odbiorniku</h2>
<div id="list" class="card"><span class="empty">Ładowanie…</span></div>
</main><script>
const $=s=>document.querySelector(s),drop=$('#drop'),pick=$('#pick'),up=$('#up');
const fmt=b=>b<1024?b+' B':b<1048576?(b/1024).toFixed(1)+' KB':b<1073741824?(b/1048576).toFixed(1)+' MB':(b/1073741824).toFixed(2)+' GB';
const esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const queue=[];let busy=false;
function add(files){for(const f of files){up.style.display='block';const r=document.createElement('div');r.className='row';
 r.innerHTML=`<span class="n">${esc(f.name)}</span><span class="s">${fmt(f.size)}</span><progress max="100" value="0"></progress><span class="st s">czeka</span>`;
 up.prepend(r);queue.push({f,r});}next();}
function next(){if(busy||!queue.length)return;busy=true;const {f,r}=queue.shift(),pb=r.querySelector('progress'),st=r.querySelector('.st');
 const x=new XMLHttpRequest();x.open('POST','/upload?name='+encodeURIComponent(f.name));
 x.upload.onprogress=e=>{if(e.lengthComputable){pb.value=e.loaded/e.total*100;st.textContent=Math.round(pb.value)+'%';}};
 const done=(ok,msg)=>{st.textContent=msg;st.className='st s '+(ok?'ok':'err');if(ok)pb.value=100;busy=false;load();next();};
 x.onload=()=>x.status==200?done(true,'✓ wysłano'):done(false,'błąd '+x.status);x.onerror=()=>done(false,'błąd sieci');x.send(f);}
drop.onclick=()=>pick.click();pick.onchange=()=>{add(pick.files);pick.value='';};
['dragenter','dragover'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('over');}));
['dragleave','drop'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove('over');}));
drop.addEventListener('drop',e=>add(e.dataTransfer.files));
$('#sendTxt').onclick=()=>{const t=$('#txt').value;if(!t.trim())return;const d=new Date(),p=n=>String(n).padStart(2,'0');
 const name=`tekst_${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}_${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}.txt`;
 add([new File([t],name,{type:'text/plain'})]);$('#txt').value='';};
async function load(){try{const a=await (await fetch('/list')).json();
 $('#list').innerHTML=a.length?a.map(f=>`<div class="row"><a class="n" href="/file?name=${encodeURIComponent(f.name)}">${esc(f.name)}</a><span class="s">${fmt(f.size)}</span><span class="s">${f.time}</span></div>`).join(''):'<span class="empty">Brak plików</span>';}catch(e){}}
// Notatki: navigator.clipboard działa tylko na https/localhost, dlatego zapasowo execCommand
function copy(t,btn){const ok=()=>{btn.textContent='✓ skopiowano';setTimeout(()=>btn.textContent='Kopiuj',1500);};
 const old=()=>{const ta=document.createElement('textarea');ta.value=t;ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);ta.select();
  try{if(document.execCommand('copy'))ok();}catch(e){}ta.remove();};
 if(navigator.clipboard&&window.isSecureContext)navigator.clipboard.writeText(t).then(ok,old);else old();}
let notes=[],notesKey='';
async function loadNotes(){try{const a=await (await fetch('/notes')).json(),k=JSON.stringify(a);if(k===notesKey)return;notesKey=k;notes=a;
 $('#notes').innerHTML=a.length?a.map((n,i)=>`<div class="note"><pre>${esc(n.text)}</pre><div class="bar"><span class="s">${n.time}</span><button data-c="${i}">Kopiuj</button><button class="sec" data-d="${esc(n.id)}">Usuń</button></div></div>`).join(''):'<span class="empty">Brak notatek</span>';}catch(e){}}
$('#notes').onclick=async e=>{const b=e.target.closest('button');if(!b)return;
 if(b.dataset.c!==undefined)copy(notes[b.dataset.c].text,b);
 else if(b.dataset.d){await fetch('/notes/delete?id='+encodeURIComponent(b.dataset.d),{method:'POST'});loadNotes();}};
$('#saveNote').onclick=async()=>{const t=$('#txt').value;if(!t.trim())return;
 const r=await fetch('/notes',{method:'POST',headers:{'Content-Type':'text/plain; charset=utf-8'},body:t});if(r.ok){$('#txt').value='';loadNotes();}};
load();loadNotes();setInterval(()=>{load();loadNotes();},3000);
</script></body></html>
'@

function Send-Bytes($res, [byte[]]$bytes, $type, $code = 200) {
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Send-Text($res, $text, $type = 'text/plain; charset=utf-8', $code = 200) {
    Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($text)) $type $code
}
function Get-Param($req, $key) {
    $parts = $req.RawUrl.Split('?', 2)
    if ($parts.Count -lt 2) { return $null }
    foreach ($p in $parts[1].Split('&')) {
        $kv = $p.Split('=', 2)
        if ($kv[0] -eq $key -and $kv.Count -eq 2) { return [Uri]::UnescapeDataString($kv[1]) }
    }
    return $null
}
function Get-SafeName($name) {
    if (-not $name) { return 'plik' }
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$c, '_') }
    $name = $name.Trim(' ', '.')
    if (-not $name) { return 'plik' }
    return $name
}

$NotesFile = Join-Path $env:APPDATA 'Odbiornik\notatki.json'
function Get-Notes {
    if (-not (Test-Path -LiteralPath $NotesFile)) { return @() }
    # PS 5.1 zwraca tablicę z ConvertFrom-Json jako jeden obiekt - przypisanie i zwrot rozwija ją
    $notes = [IO.File]::ReadAllText($NotesFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $notes
}
function Save-Notes($notes) {
    New-Item -ItemType Directory -Force -Path (Split-Path $NotesFile) | Out-Null
    [IO.File]::WriteAllText($NotesFile, (ConvertTo-Json -InputObject @($notes) -Depth 3), (New-Object Text.UTF8Encoding $false))
}

function Handle($ctx) {
    $req = $ctx.Request; $res = $ctx.Response
    $path = $req.Url.AbsolutePath

    if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
        Send-Text $res $Html 'text/html; charset=utf-8'
    }
    elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/list') {
        $items = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Extension -ne '.part' } |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { [pscustomobject]@{ name = $_.Name; size = $_.Length; time = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } })
        Send-Text $res (ConvertTo-Json -InputObject $items -Compress) 'application/json; charset=utf-8'
    }
    elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/notes') {
        Send-Text $res (ConvertTo-Json -InputObject @(Get-Notes) -Compress) 'application/json; charset=utf-8'
    }
    elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/notes') {
        if ($req.ContentLength64 -gt 1MB) { Send-Text $res 'Za długi tekst' -code 413; return }
        $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd(); $reader.Close()
        $note = [pscustomobject]@{ id = [guid]::NewGuid().ToString('N'); text = $text; time = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
        Save-Notes (@($note) + @(Get-Notes))
        Write-Host ("[{0}] Nowa notatka od {1}" -f (Get-Date -Format HH:mm:ss), $req.RemoteEndPoint.Address) -ForegroundColor Green
        Send-Text $res 'ok'
    }
    elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/notes/delete') {
        $id = Get-Param $req 'id'
        Save-Notes @(Get-Notes | Where-Object { $_.id -ne $id })
        Send-Text $res 'ok'
    }
    elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/upload') {
        $name = Get-SafeName (Get-Param $req 'name')
        $base = [IO.Path]::GetFileNameWithoutExtension($name); $ext = [IO.Path]::GetExtension($name)
        $target = Join-Path $Dir $name; $i = 1
        while (Test-Path -LiteralPath $target) { $target = Join-Path $Dir "$base ($i)$ext"; $i++ }
        $tmp = "$target.part"
        try {
            $fs = [IO.File]::Create($tmp)
            try { $req.InputStream.CopyTo($fs, 1MB) } finally { $fs.Close() }
            Move-Item -LiteralPath $tmp -Destination $target
        } catch {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            throw
        }
        $size = (Get-Item -LiteralPath $target).Length
        Write-Host ("[{0}] Odebrano: {1} ({2:N1} MB) od {3}" -f (Get-Date -Format HH:mm:ss), (Split-Path $target -Leaf), ($size / 1MB), $req.RemoteEndPoint.Address) -ForegroundColor Green
        Send-Text $res 'ok'
    }
    elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/file') {
        $name = Get-SafeName (Get-Param $req 'name')
        $file = Join-Path $Dir $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-Text $res 'Nie ma takiego pliku' -code 404; return }
        $fs = [IO.File]::OpenRead($file)
        try {
            $res.ContentType = 'application/octet-stream'
            $res.ContentLength64 = $fs.Length
            $res.AddHeader('Content-Disposition', "attachment; filename*=UTF-8''" + [Uri]::EscapeDataString($name))
            $fs.CopyTo($res.OutputStream, 1MB)
        } finally { $fs.Close() }
    }
    else { Send-Text $res 'Not found' -code 404 }
}

function Start-Listener($prefix) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add($prefix)
    $l.Start()
    $l
}
# Port 80 = adres bez ":port". Jak zajęty, to zapasowy. Bez admina tylko lokalnie.
$listener = $null
foreach ($p in $Port, $FallbackPort) {
    try { $listener = Start-Listener "http://+:$p/"; $Port = $p; break } catch { }
}
if (-not $listener) {
    Write-Host "Brak uprawnień admina - działa tylko lokalnie (uruchom przez Odbiornik.bat)" -ForegroundColor Yellow
    $listener = Start-Listener "http://localhost:$FallbackPort/"; $Port = $FallbackPort
}

$responder = [powershell]::Create().AddScript($NameResponder).AddArgument($Name)
[void]$responder.BeginInvoke()

$suffix = if ($Port -eq 80) { '' } else { ":$Port" }
$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object IPAddress

$Host.UI.RawUI.WindowTitle = 'Odbiornik plików'
Write-Host ''
Write-Host '  ODBIORNIK PLIKÓW DZIAŁA' -ForegroundColor Cyan
Write-Host '  Na drugim komputerze otwórz w przeglądarce:' -ForegroundColor Gray
Write-Host "     http://$Name$suffix" -ForegroundColor White
Write-Host "     (jak nie działa: http://$Name.local$suffix" -NoNewline -ForegroundColor DarkGray
foreach ($ip in $ips) { Write-Host "  albo  http://$ip$suffix" -NoNewline -ForegroundColor DarkGray }
Write-Host ')' -ForegroundColor DarkGray
Write-Host "  Pliki zapisują się w: $Dir" -ForegroundColor Gray
Write-Host '  Zamknij to okno, żeby wyłączyć.' -ForegroundColor Gray
Write-Host ''
Start-Process explorer.exe $Dir

while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.Wait(500)) { }
    $ctx = $task.Result
    try { Handle $ctx }
    catch { Write-Host "Błąd: $($_.Exception.Message)" -ForegroundColor Red; try { $ctx.Response.StatusCode = 500 } catch { } }
    finally { try { $ctx.Response.Close() } catch { } }
}
