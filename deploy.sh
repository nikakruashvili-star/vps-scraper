#!/bin/bash
# ══════════════════════════════════════════════════════════════
# Cosmotron Border Queue Scraper — ONE-COMMAND VPS DEPLOY
# ══════════════════════════════════════════════════════════════

set -euo pipefail

SCRAPER_DIR="/opt/border-scraper"
PORT=3100
API_KEY=$(openssl rand -hex 24)
PUBLIC_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "YOUR_VPS_IP")

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  🚛 Cosmotron Border Queue Scraper — Auto Deploy"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── 1. System dependencies ──────────────────────────────────
echo "► Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq curl git openssl cron > /dev/null 2>&1

# ── 2. Node.js 20 LTS ───────────────────────────────────────
if ! command -v node &> /dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 20 ]]; then
  echo "► Installing Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
fi
echo "  Node $(node -v) / npm $(npm -v)"

# ── 3. Create project directory ─────────────────────────────
echo "► Setting up $SCRAPER_DIR..."
mkdir -p "$SCRAPER_DIR"

# ── 4. Write application files inline ───────────────────────
echo "► Writing scraper files..."

# ─── package.json ───
cat > "$SCRAPER_DIR/package.json" << 'PACKAGE_EOF'
{
  "name": "cosmotron-border-scraper",
  "version": "1.0.0",
  "description": "Playwright-based border queue scraper",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "scrape": "node scraper.js"
  },
  "dependencies": {
    "playwright": "^1.44.0",
    "express": "^4.19.2",
    "better-sqlite3": "^11.1.2"
  }
}
PACKAGE_EOF

# ─── scraper.js ───
cat > "$SCRAPER_DIR/scraper.js" << 'SCRAPER_EOF'
const { chromium } = require('playwright');
const Database = require('better-sqlite3');
const path = require('path');

const DB_PATH = path.join(__dirname, 'border_queue_cache.db');

const THROUGHPUT_PER_HOUR = {
  sarp: 70,
  kapikule: 90,
  turkgozu: 60,
  cildir: 55,
  larsi: 65,
  red_bridge: 50,
};

function estimateWaitHours(truckCount, gate) {
  const rate = THROUGHPUT_PER_HOUR[gate] || 40;
  return Math.round((truckCount / rate) * 10) / 10;
}

function formatWait(hours) {
  if (hours < 1) return Math.round(hours * 60) + 'm';
  const h = Math.floor(hours);
  const m = Math.round((hours - h) * 60);
  return m > 0 ? h + 'h ' + m + 'm' : h + 'h';
}

function getDb() {
  const db = new Database(DB_PATH);
  db.pragma('journal_mode = WAL');
  db.exec(
    "CREATE TABLE IF NOT EXISTS border_queue_cache (" +
    "border_name TEXT PRIMARY KEY, country TEXT NOT NULL, truck_count INTEGER DEFAULT 0, " +
    "estimated_wait TEXT DEFAULT '0m', estimated_wait_hours REAL DEFAULT 0, " +
    "confidence REAL DEFAULT 0, source TEXT DEFAULT 'unknown', " +
    "last_updated TEXT DEFAULT (datetime('now')));"
  );
  return db;
}

function upsertCache(db, data) {
  db.prepare(
    "INSERT INTO border_queue_cache (border_name, country, truck_count, estimated_wait, estimated_wait_hours, confidence, source, last_updated) " +
    "VALUES (@border_name, @country, @truck_count, @estimated_wait, @estimated_wait_hours, @confidence, @source, datetime('now')) " +
    "ON CONFLICT(border_name) DO UPDATE SET country=@country, truck_count=@truck_count, estimated_wait=@estimated_wait, " +
    "estimated_wait_hours=@estimated_wait_hours, confidence=@confidence, source=@source, last_updated=datetime('now')"
  ).run(data);
}

function parseTurkishPage(html, gateName) {
  var nameVariants = {
    sarp: ['Sarp','sarp','SARP'],
    turkgozu: ['Turkgozu','turkgocu','TURKGOZU'],
    cildir: ['Aktas','Cildir','AKTAS','CILDIR'],
    kapikule: ['Kapikule','kapikule','KAPIKULE'],
  };
  var variants = nameVariants[gateName] || [gateName];
  for (var i = 0; i < variants.length; i++) {
    var name = variants[i];
    var patterns = [
      new RegExp(name + '[^<]{0,300}?(\\d+)\\s*(?:TIR|kamyon|truck)', 'i'),
      new RegExp(name + '[^<]{0,200}?kuyruk[^<]{0,100}?(\\d+)', 'i'),
      new RegExp(name + '[^<]{0,200}?bekleme[^<]{0,100}?(\\d+)', 'i'),
    ];
    for (var j = 0; j < patterns.length; j++) {
      var m = html.match(patterns[j]);
      if (m) { var c = parseInt(m[1],10); if (c >= 0 && c < 10000) return c; }
    }
  }
  var generics = [/(?:TIR|kamyon|truck)[:\s]*(\d+)/i, /kuyruk[:\s]*(\d+)/i];
  for (var k = 0; k < generics.length; k++) {
    var mg = html.match(generics[k]);
    if (mg) { var cg = parseInt(mg[1],10); if (cg >= 0 && cg < 10000) return cg; }
  }
  return null;
}

function parseZiticPage(html) {
  var patterns = [/queue[:\s]*(\d+)/i, /trucks?[:\s]*(\d+)/i];
  for (var i = 0; i < patterns.length; i++) {
    var m = html.match(patterns[i]);
    if (m) return parseInt(m[1], 10);
  }
  return null;
}

function parseBulgarianPage(html) {
  var patterns = [
    /Kapitan\s*Andreevo[^<]{0,200}?(\d+)\s*(?:trucks?|TIR)/i,
    /Andreevo[^<]{0,150}?queue[^<]{0,50}?(\d+)/i,
    /(?:trucks?|TIR)[:\s]*(\d+)/i,
  ];
  for (var i = 0; i < patterns.length; i++) {
    var m = html.match(patterns[i]);
    if (m) { var c = parseInt(m[1],10); if (c >= 0 && c < 10000) return c; }
  }
  return null;
}

async function scrapePage(browser, url, timeout) {
  timeout = timeout || 20000;
  var page = await browser.newPage();
  try {
    await page.goto(url, { waitUntil: 'networkidle', timeout: timeout });
    return await page.content();
  } catch(e) { console.error('  x ' + url + ': ' + e.message); return null; }
  finally { await page.close(); }
}

function fallbackEstimation(borderName, country, source) {
  var db = getDb();
  var cached = db.prepare('SELECT * FROM border_queue_cache WHERE border_name = ?').get(borderName);
  db.close();
  if (cached && cached.truck_count > 0)
    return { border_name: borderName, country: country, truck_count: cached.truck_count,
      estimated_wait: cached.estimated_wait, estimated_wait_hours: cached.estimated_wait_hours,
      confidence: Math.max(0.2, (cached.confidence||0.5)-0.3), source: 'fallback:' + source };
  return { border_name: borderName, country: country, truck_count: 0, estimated_wait: '—',
    estimated_wait_hours: 0, confidence: 0.1, source: 'no_data:' + source };
}

async function scrapeSarp(browser) {
  var urls = ['https://ticaret.gov.tr/gumrukler/sarp','https://sarp.sinir.gov.tr'];
  for (var i = 0; i < urls.length; i++) {
    var html = await scrapePage(browser, urls[i]);
    if (html) { var t = parseTurkishPage(html, 'sarp');
      if (t !== null) { var wh = estimateWaitHours(t, 'sarp');
        return { border_name:'sarp', country:'Turkey', truck_count:t, estimated_wait:formatWait(wh),
          estimated_wait_hours:wh, confidence:0.9, source:'turkey_customs:'+urls[i] }; } }
  }
  return fallbackEstimation('sarp','Turkey','sarp');
}

async function scrapeKapikule(browser) {
  var trUrls = ['https://ticaret.gov.tr/gumrukler/sinir-kapilari','https://kapikule.sinir.gov.tr'];
  var bgUrls = ['https://www.bgtraffic.bg/en/border-checkpoints'];
  var trTrucks = null, trSource = '';
  for (var i = 0; i < trUrls.length; i++) {
    var html = await scrapePage(browser, trUrls[i]);
    if (html) { var t = parseTurkishPage(html, 'kapikule');
      if (t !== null) { trTrucks = t; trSource = 'turkey_customs:'+trUrls[i]; break; } }
  }
  var bgTrucks = null;
  for (var j = 0; j < bgUrls.length; j++) {
    var bhtml = await scrapePage(browser, bgUrls[j]);
    if (bhtml) { var bt = parseBulgarianPage(bhtml);
      if (bt !== null) { bgTrucks = bt; break; } }
  }
  if (trTrucks !== null) {
    var confidence = 0.9, source = trSource;
    if (bgTrucks !== null) {
      var disc = Math.abs(trTrucks - bgTrucks) / Math.max(trTrucks, bgTrucks, 1);
      if (disc > 0.3) { confidence = 0.75; source += '+discrepancy:bg='+bgTrucks;
        console.log('  ! Kapikule discrepancy: TR='+trTrucks+', BG='+bgTrucks); }
      else { confidence = 0.9; source += '+crosscheck_ok:bgtraffic.bg'; }
    }
    var wh = estimateWaitHours(trTrucks, 'kapikule');
    return { border_name:'kapikule', country:'Turkey', truck_count:trTrucks,
      estimated_wait:formatWait(wh), estimated_wait_hours:wh, confidence:confidence, source:source };
  }
  if (bgTrucks !== null) { var wh2 = estimateWaitHours(bgTrucks, 'kapikule');
    return { border_name:'kapikule', country:'Turkey', truck_count:bgTrucks,
      estimated_wait:formatWait(wh2), estimated_wait_hours:wh2, confidence:0.6, source:'fallback:bgtraffic.bg' }; }
  return fallbackEstimation('kapikule','Turkey','kapikule');
}

async function scrapeTurkgozu(browser) {
  var urls = ['https://ticaret.gov.tr/gumrukler/turkgocu'];
  for (var i = 0; i < urls.length; i++) {
    var html = await scrapePage(browser, urls[i]);
    if (html) { var t = parseTurkishPage(html, 'turkgozu');
      if (t !== null) { var wh = estimateWaitHours(t, 'turkgozu');
        return { border_name:'turkgozu', country:'Turkey', truck_count:t, estimated_wait:formatWait(wh),
          estimated_wait_hours:wh, confidence:0.9, source:'turkey_customs:'+urls[i] }; } }
  }
  return fallbackEstimation('turkgozu','Turkey','turkgozu');
}

async function scrapeCildir(browser) {
  var urls = ['https://ticaret.gov.tr/gumrukler/cildir','https://cildir.sinir.gov.tr'];
  for (var i = 0; i < urls.length; i++) {
    var html = await scrapePage(browser, urls[i]);
    if (html) { var t = parseTurkishPage(html, 'cildir');
      if (t !== null) { var wh = estimateWaitHours(t, 'cildir');
        return { border_name:'cildir', country:'Turkey', truck_count:t, estimated_wait:formatWait(wh),
          estimated_wait_hours:wh, confidence:0.9, source:'turkey_customs:'+urls[i] }; } }
  }
  return fallbackEstimation('cildir','Turkey','cildir');
}

async function scrapeLarsi(browser) {
  var html = await scrapePage(browser, 'https://zitic.ru/eo/vl/', 25000);
  if (html) { var t = parseZiticPage(html);
    if (t !== null && t >= 0) { var wh = estimateWaitHours(t, 'larsi');
      return { border_name:'larsi', country:'Russia', truck_count:t, estimated_wait:formatWait(wh),
        estimated_wait_hours:wh, confidence:0.9, source:'zitic.ru' }; } }
  return fallbackEstimation('larsi','Russia','larsi');
}

async function runScraper() {
  console.log('[' + new Date().toISOString() + '] Starting scraper...');
  var browser = await chromium.launch({ headless:true, args:['--no-sandbox','--disable-setuid-sandbox','--disable-dev-shm-usage'] });
  var db = getDb();
  try {
    var jobs = await Promise.allSettled([scrapeSarp(browser),scrapeKapikule(browser),scrapeTurkgozu(browser),scrapeCildir(browser),scrapeLarsi(browser)]);
    for (var i = 0; i < jobs.length; i++) {
      if (jobs[i].status === 'fulfilled' && jobs[i].value) {
        upsertCache(db, jobs[i].value);
        console.log('  ok ' + jobs[i].value.border_name + ': ' + jobs[i].value.truck_count + ' trucks (' + jobs[i].value.estimated_wait + ')');
      } else if (jobs[i].status === 'rejected') console.error('  err', jobs[i].reason);
    }
    console.log('[' + new Date().toISOString() + '] Done.');
  } finally { await browser.close(); db.close(); }
}

if (require.main === module) runScraper().catch(console.error);
module.exports = { runScraper, getDb };
SCRAPER_EOF

# ─── server.js ───
cat > "$SCRAPER_DIR/server.js" << 'SERVER_EOF'
const express = require('express');
const { getDb } = require('./scraper');
const app = express();
const PORT = process.env.PORT || 3100;
const API_KEY = process.env.SCRAPER_API_KEY || '';

app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Headers', 'x-api-key, content-type');
  if (req.method === 'OPTIONS') return res.sendStatus(200);
  next();
});

function auth(req, res, next) {
  if (!API_KEY) return next();
  if ((req.headers['x-api-key'] || req.query.api_key) !== API_KEY) return res.status(401).json({ error: 'Unauthorized' });
  next();
}

app.get('/api/border-queues', auth, (req, res) => {
  try {
    var db = getDb();
    var rows = db.prepare('SELECT * FROM border_queue_cache').all();
    db.close();
    var out = {}, latest = null;
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
      out[r.border_name] = { trucks: r.truck_count, wait_time: r.estimated_wait, wait_hours: r.estimated_wait_hours,
        confidence: r.confidence, source: r.source, country: r.country, last_updated: r.last_updated };
      if (!latest || r.last_updated > latest) latest = r.last_updated;
    }
    out.updated_at = latest || new Date().toISOString();
    res.json(out);
  } catch(e) { console.error(e); res.status(500).json({ error: 'Internal error' }); }
});

app.get('/health', function(_, res) { res.json({ status: 'ok', timestamp: new Date().toISOString() }); });
app.listen(PORT, function() { console.log('Border Queue API on :' + PORT); });
SERVER_EOF

# ── 5. Install npm dependencies ─────────────────────────────
echo "► Installing npm packages..."
cd "$SCRAPER_DIR"
npm install --production --silent 2>&1 | tail -1

# ── 6. Install Playwright Chromium + OS deps ────────────────
echo "► Installing Playwright Chromium (this may take a minute)..."
npx playwright install chromium --with-deps 2>&1 | tail -3

# ── 7. Write environment file ───────────────────────────────
echo "► Generating API key and .env..."
cat > "$SCRAPER_DIR/.env" << EOF
PORT=$PORT
SCRAPER_API_KEY=$API_KEY
EOF

# ── 8. Create systemd service ───────────────────────────────
echo "► Configuring systemd service..."
cat > /etc/systemd/system/border-scraper-api.service << EOF
[Unit]
Description=Cosmotron Border Queue API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$SCRAPER_DIR
EnvironmentFile=$SCRAPER_DIR/.env
ExecStart=$(which node) server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable border-scraper-api --quiet
systemctl restart border-scraper-api

# ── 9. Configure cron (every 10 min) ────────────────────────
echo "► Setting up cron job (every 10 minutes)..."
cat > /etc/cron.d/border-scraper << EOF
*/10 * * * * root cd $SCRAPER_DIR && $(which node) scraper.js >> /var/log/border-scraper.log 2>&1
EOF
chmod 644 /etc/cron.d/border-scraper

cat > /etc/logrotate.d/border-scraper << 'EOF'
/var/log/border-scraper.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
}
EOF

# ── 10. Open firewall port ──────────────────────────────────
if command -v ufw &> /dev/null; then
  echo "► Opening port $PORT in UFW..."
  ufw allow $PORT/tcp > /dev/null 2>&1 || true
fi

# ── 11. Run first scrape ────────────────────────────────────
echo "► Running initial scrape..."
cd "$SCRAPER_DIR" && node scraper.js 2>&1 || echo "  (initial scrape had warnings — cron will retry)"

# ── 12. Verify API is running ───────────────────────────────
sleep 2
API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/health" 2>/dev/null || echo "000")

echo ""
echo "═══════════════════════════════════════════════════════"
if [ "$API_STATUS" = "200" ]; then
  echo "  ✅ DEPLOYMENT COMPLETE — API is running!"
else
  echo "  ⚠️  DEPLOYMENT COMPLETE — API may still be starting"
fi
echo ""
echo "  API URL:  http://$PUBLIC_IP:$PORT/api/border-queues"
echo "  API KEY:  $API_KEY"
echo "  Health:   http://$PUBLIC_IP:$PORT/health"
echo ""
echo "  ┌─────────────────────────────────────────────────┐"
echo "  │  Save these for Lovable Cloud secrets:          │"
echo "  │                                                 │"
echo "  │  VPS_SCRAPER_URL = http://$PUBLIC_IP:$PORT      │"
echo "  │  VPS_SCRAPER_API_KEY = $API_KEY                 │"
echo "  └─────────────────────────────────────────────────┘"
echo ""
echo "  Test:  curl -H 'x-api-key: $API_KEY' http://$PUBLIC_IP:$PORT/api/border-queues"
echo "  Logs:  journalctl -u border-scraper-api -f"
echo "  Cron:  tail -f /var/log/border-scraper.log"
echo "═══════════════════════════════════════════════════════"
