const fs = require('fs');
const path = require('path');
const https = require('https');
const { execSync } = require('child_process');
const os = require('os');

const REPO = 'xdvi/zero-noise';
const VERSION = process.env.ZERO_NOISE_VERSION || 'latest';

function detectTarget() {
    const arch = os.arch();
    const platform = os.platform();
    let a = arch === 'x64' ? 'x86_64' : (arch === 'arm64' ? 'aarch64' : arch);
    let osname = platform === 'darwin' ? 'macos' : (platform === 'win32' ? 'windows' : 'linux');
    if (osname === 'windows') return { target: 'x86_64-windows-gnu', ext: 'zip', binary: 'zero-noise.exe' };
    if (a === 'x86_64' && osname === 'linux') return { target: 'x86_64-linux-musl', ext: 'tar.gz', binary: 'zero-noise' };
    if (a === 'aarch64' && osname === 'linux') return { target: 'aarch64-linux-musl', ext: 'tar.gz', binary: 'zero-noise' };
    if (a === 'aarch64' && osname === 'macos') return { target: 'aarch64-macos', ext: 'tar.gz', binary: 'zero-noise' };
    if (a === 'x86_64' && osname === 'macos') return { target: 'x86_64-macos', ext: 'tar.gz', binary: 'zero-noise' };
    return null;
}

function handleResponse(res, file, dest, resolve, reject) {
    if (res.statusCode === 302 || res.statusCode === 301) {
        download(res.headers.location, dest).then(resolve).catch(reject);
        return;
    }
    if (res.statusCode !== 200) {
        reject(new Error('HTTP ' + res.statusCode));
        return;
    }
    res.pipe(file);
    file.on('finish', () => {
        file.close();
        resolve();
    });
}

function executeDownload(url, dest, resolve, reject) {
    const file = fs.createWriteStream(dest);
    https.get(url, (res) => handleResponse(res, file, dest, resolve, reject)).on('error', reject);
}

function download(url, dest) {
    return new Promise((resolve, reject) => executeDownload(url, dest, resolve, reject));
}

function tryBuildFromSource(target, binaryPath) {
    const buildFile = path.join(__dirname, '..', 'build.zig');
    if (!fs.existsSync(buildFile)) {
        return false;
    }
    try {
        execSync('zig build -Doptimize=ReleaseFast', {
            stdio: 'inherit',
            cwd: path.join(__dirname, '..'),
        });
    } catch {}
    const binaryName = target.binary || target;
    const built = path.join(__dirname, '..', 'zig-out', 'bin', binaryName);
    if (!fs.existsSync(built)) {
        return false;
    }
    fs.copyFileSync(built, binaryPath);
    fs.chmodSync(binaryPath, 0o755);
    console.log('Built from source.');
    return true;
}

async function main() {
    const t = detectTarget();
    if (!t) {
        console.error('Unsupported platform: ' + os.platform() + ' ' + os.arch());
        process.exit(1);
    }
    const binDir = path.join(__dirname, '..', 'bin');
    fs.mkdirSync(binDir, { recursive: true });
    const binaryPath = path.join(binDir, t.binary);
    if (fs.existsSync(binaryPath)) {
        console.log('zero-noise binary already present.');
        return;
    }
    const url = VERSION === 'latest'
        ? `https://github.com/${REPO}/releases/latest/download/zero-noise-${t.target}.${t.ext}`
        : `https://github.com/${REPO}/releases/download/${VERSION}/zero-noise-${t.target}.${t.ext}`;
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zn-'));
    const archive = path.join(tmpDir, 'archive.' + t.ext);
    console.log('Downloading zero-noise binary...');
    try {
        await download(url, archive);
    } catch (e) {
        console.error('Download failed: ' + e.message);
        if (tryBuildFromSource(t, binaryPath)) {
            return;
        }
        process.exit(1);
    }
    // extract
    if (t.ext === 'zip') {
        execSync(`unzip -q -o "${archive}" -d "${tmpDir}"`);
        fs.copyFileSync(path.join(tmpDir, t.binary), binaryPath);
    } else {
        execSync(`tar -xzf "${archive}" -C "${tmpDir}"`);
        fs.copyFileSync(path.join(tmpDir, t.binary), binaryPath);
    }
    fs.chmodSync(binaryPath, 0o755);
    console.log('Installed zero-noise to ' + binaryPath);

    // Make available on PATH for MCP servers that invoke `zero-noise`.
    const home = os.homedir();
    const localBin = path.join(home, '.local', 'bin');
    try { fs.mkdirSync(localBin, { recursive: true }); } catch {}
    const targetBin = path.join(localBin, t.binary);
    try { fs.copyFileSync(binaryPath, targetBin); fs.chmodSync(targetBin, 0o755); console.log('Linked to ' + targetBin); } catch (e) { console.warn('Could not link to PATH: ' + e.message); }
}

main().catch((e) => { console.error(e); process.exit(1); });