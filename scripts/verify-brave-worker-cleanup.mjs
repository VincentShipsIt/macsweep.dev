// Isolated capability probe. It never attaches to, quits or reads a user's browser profile.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {createServer} from 'node:http';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

const profile = await mkdtemp(join(tmpdir(), 'macsweep-brave-capability-'));
const browserPath = process.env.MACSWEEP_TEST_BRAVE ?? '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';
const server = createServer((request, response) => {
    response.setHeader('Content-Type', request.url === '/sw.js' ? 'text/javascript' : 'text/html');
    if (request.url === '/sw.js') {
        response.end("self.addEventListener('install', e => self.skipWaiting()); self.addEventListener('activate', e => e.waitUntil(clients.claim()));");
    } else if (request.url === '/account') {
        response.statusCode = request.headers.cookie?.includes('session=preserved') ? 200 : 401;
        response.end('fixture account');
    } else {
        response.end('<!doctype html><title>MacSweep isolated worker capability</title>Fixture only');
    }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = spawn(browserPath, ['--headless=new', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--disable-sync', '--password-store=basic', '--remote-debugging-port=0',
    `--user-data-dir=${profile}`, origin], {stdio: 'ignore'});
let socket;
let commandID = 0;
const pending = new Map();
try {
    browser.on('error', error => { throw error; });
    let port;
    for (let attempt = 0; attempt < 200; attempt++) {
        if (browser.exitCode !== null) throw new Error('Isolated Brave exited before debugging became ready');
        try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; break; }
        catch { await delay(50); }
    }
    assert(port, 'isolated debugging endpoint must start');
    let page;
    for (let attempt = 0; attempt < 100; attempt++) {
        page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(target => target.type === 'page' && target.url.startsWith(origin));
        if (page) break;
        await delay(50);
    }
    assert(page, 'isolated fixture page must exist');
    socket = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    socket.onmessage = ({data}) => {
        const message = JSON.parse(data);
        if (!pending.has(message.id)) return;
        const {resolve, reject, timeout} = pending.get(message.id);
        clearTimeout(timeout);
        pending.delete(message.id);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result);
    };
    const command = (method, params = {}) => new Promise((resolve, reject) => {
        const id = ++commandID;
        const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`Timed out: ${method}`)); }, 10000);
        pending.set(id, {resolve, reject, timeout});
        socket.send(JSON.stringify({id, method, params}));
    });
    const evaluate = async expression => {
        const value = await command('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true});
        if (value.exceptionDetails) throw new Error(JSON.stringify(value.exceptionDetails));
        return value.result.value;
    };
    for (let attempt = 0; attempt < 200; attempt++) {
        const ready = await evaluate('({href: location.href, origin: location.origin, ready: document.readyState})');
        if (ready.origin === origin && ready.ready === 'complete') break;
        if (attempt === 199) throw new Error(JSON.stringify(ready));
        await delay(50);
    }
    await evaluate(`(async () => {
        document.cookie = 'session=preserved; SameSite=Lax';
        localStorage.setItem('login', 'preserved'); sessionStorage.setItem('tab-session', 'preserved');
        const request = indexedDB.open('login-fixture', 1);
        await new Promise((resolve, reject) => { request.onupgradeneeded = () => request.result.createObjectStore('tokens');
            request.onsuccess = () => { const transaction = request.result.transaction('tokens', 'readwrite');
                transaction.objectStore('tokens').put('preserved', 'login'); transaction.oncomplete = () => { request.result.close(); resolve(); }; };
            request.onerror = reject; });
        await navigator.serviceWorker.register('/sw.js'); await navigator.serviceWorker.ready;
        const cache = await caches.open('worker-fixture'); await cache.put('/offline', new Response('fixture'));
        return true;
    })()`);
    assert.equal(await evaluate('(async()=> (await navigator.serviceWorker.getRegistrations()).length)()'), 1);
    assert.equal((await command('CacheStorage.requestCacheNames', {securityOrigin: origin})).caches.length, 1);
    await command('ServiceWorker.enable');
    await command('ServiceWorker.unregister', {scopeURL: `${origin}/`});
    const caches = (await command('CacheStorage.requestCacheNames', {securityOrigin: origin})).caches;
    // Unregistration and Cache Storage eviction are separate operations.
    assert.equal(caches.length, 1, 'unregister must leave Cache Storage until explicitly evicted');
    for (const cache of caches) await command('CacheStorage.deleteCache', {cacheId: cache.cacheId});
    await command('Network.clearBrowserCache');
    for (let attempt = 0; attempt < 100; attempt++) {
        if (await evaluate('(async()=> (await navigator.serviceWorker.getRegistrations()).length)()') === 0) break;
        await delay(20);
    }
    assert.equal(await evaluate('(async()=> (await navigator.serviceWorker.getRegistrations()).length)()'), 0);
    assert.deepEqual(await evaluate('(async()=> await caches.keys())()'), []);
    assert.equal(await evaluate("document.cookie.includes('session=preserved')"), true);
    assert.equal(await evaluate("localStorage.getItem('login')"), 'preserved');
    assert.equal(await evaluate("sessionStorage.getItem('tab-session')"), 'preserved');
    assert.equal(await evaluate("(async()=> (await fetch('/account')).status)()"), 200);
    assert.equal(await evaluate(`new Promise((resolve, reject) => {const request = indexedDB.open('login-fixture', 1);
        request.onsuccess = () => { const get = request.result.transaction('tokens').objectStore('tokens').get('login');
            get.onsuccess = () => { request.result.close(); resolve(get.result); }; get.onerror = reject; }; request.onerror = reject;})`), 'preserved');
    assert.equal(browser.exitCode, null, 'isolated Brave must remain open during all assertions');
    const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    console.log(JSON.stringify({browser: version.Browser, protocol: version['Protocol-Version'],
        workerRegistrationRemoved: true, workerCacheEvicted: true, httpCacheCommandSucceeded: true,
        cookie: 'preserved', localStorage: 'preserved', sessionStorage: 'preserved', indexedDB: 'preserved',
        authenticatedFixtureRequest: 200, browserStayedOpen: true,
        shippingCapability: 'unsupported-without-preconfigured-debugging; no live cleanup enabled'}, null, 2));
} finally {
    socket?.close();
    for (const {timeout, reject} of pending.values()) { clearTimeout(timeout); reject(new Error('probe ending')); }
    browser.kill('SIGTERM');
    await Promise.race([new Promise(resolve => browser.once('exit', resolve)), delay(2000)]);
    if (browser.exitCode === null) browser.kill('SIGKILL');
    await new Promise(resolve => server.close(resolve));
    await rm(profile, {recursive: true, force: true});
}
