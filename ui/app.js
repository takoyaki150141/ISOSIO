// State Management
let currentResults = [];
let lockedAddresses = new Set();
let selectedAddress = null;
let selectedType = 'i32';

// DOM Elements
const selectType = document.getElementById('select-type');
const inputValue = document.getElementById('input-value');
const btnFirstScan = document.getElementById('btn-first-scan');
const btnNextScan = document.getElementById('btn-next-scan');
const btnClear = document.getElementById('btn-clear');
const statusText = document.getElementById('status-text');
const loader = document.getElementById('loader');
const resultsBody = document.getElementById('results-body');

const speedSlider = document.getElementById('speed-slider');
const speedVal = document.getElementById('speed-val');
const speedInput = document.getElementById('speed-input');
const speedFill = document.getElementById('speed-fill');
const btnSpeedDec = document.getElementById('btn-speed-dec');
const btnSpeedInc = document.getElementById('btn-speed-inc');
const btnSpeedReset = document.getElementById('btn-speed-reset');
const btnSpeedApply = document.getElementById('btn-speed-apply');

const editModal = document.getElementById('edit-modal');
const modalAddress = document.getElementById('modal-address');
const modalInput = document.getElementById('modal-input');
const btnModalCancel = document.getElementById('btn-modal-cancel');
const btnModalSave = document.getElementById('btn-modal-save');
const btnCloseUi = document.getElementById('btn-close-ui');

// Tab Switching
document.querySelectorAll('.nav-item').forEach(btn => {
    btn.addEventListener('click', () => {
        document.querySelectorAll('.nav-item').forEach(b => b.classList.remove('active'));
        document.querySelectorAll('.tab-content').forEach(tc => tc.classList.remove('active'));
        
        btn.classList.add('active');
        document.getElementById(btn.dataset.target).classList.add('active');
    });
});

// Helper: send message to native bridge
function sendNativeMessage(msg) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cheatEngine) {
        window.webkit.messageHandlers.cheatEngine.postMessage(msg);
    } else {
        console.log("Native message (not in iOS WKWebView):", msg);
    }
}

// Memory Scanner Actions
btnFirstScan.addEventListener('click', () => {
    const val = inputValue.value.trim();
    if (!val) return;
    
    selectedType = selectType.value;
    statusText.textContent = "Scanning memory...";
    loader.classList.remove('hidden');
    
    btnFirstScan.disabled = true;
    btnNextScan.disabled = true;
    btnClear.disabled = true;
    
    sendNativeMessage({
        action: 'firstScan',
        type: selectedType,
        value: val
    });
});

btnNextScan.addEventListener('click', () => {
    const val = inputValue.value.trim();
    if (!val) return;
    
    statusText.textContent = "Filtering results...";
    loader.classList.remove('hidden');
    
    btnFirstScan.disabled = true;
    btnNextScan.disabled = true;
    btnClear.disabled = true;
    
    sendNativeMessage({
        action: 'nextScan',
        value: val
    });
});

btnClear.addEventListener('click', () => {
    currentResults = [];
    lockedAddresses.clear();
    btnNextScan.disabled = true;
    inputValue.value = '';
    statusText.textContent = "Cleared results";
    renderResults();
    sendNativeMessage({ action: 'clear' });
});

// Speed Hack Actions
function updateSpeedUI(val) {
    speedSlider.value = val;
    speedInput.value = val;
    speedVal.textContent = parseFloat(val).toFixed(1);
    
    // Rotate speed fill gauge accordingly (max speed slider is 20, map to degrees)
    const pct = Math.min(val / 20.0, 1.0);
    const deg = -45 + (pct * 270);
    speedFill.style.transform = `rotate(${deg}deg)`;
}

speedSlider.addEventListener('input', (e) => {
    updateSpeedUI(e.target.value);
});

speedInput.addEventListener('change', (e) => {
    let val = parseFloat(e.target.value);
    if (isNaN(val) || val <= 0) val = 1.0;
    updateSpeedUI(val);
});

btnSpeedDec.addEventListener('click', () => {
    let val = parseFloat(speedInput.value) - 0.1;
    if (val < 0.1) val = 0.1;
    updateSpeedUI(val);
});

btnSpeedInc.addEventListener('click', () => {
    let val = parseFloat(speedInput.value) + 0.1;
    updateSpeedUI(val);
});

btnSpeedReset.addEventListener('click', () => {
    updateSpeedUI(1.0);
    sendNativeMessage({ action: 'setSpeed', speed: 1.0 });
});

btnSpeedApply.addEventListener('click', () => {
    const val = parseFloat(speedInput.value);
    sendNativeMessage({ action: 'setSpeed', speed: val });
});

// Close UI Overlay
btnCloseUi.addEventListener('click', () => {
    sendNativeMessage({ action: 'close' });
});

// Render results list
function renderResults() {
    resultsBody.innerHTML = '';
    
    if (currentResults.length === 0) {
        resultsBody.innerHTML = `<tr><td colspan="3" class="placeholder-row">No results.</td></tr>`;
        return;
    }
    
    currentResults.forEach(res => {
        const tr = document.createElement('tr');
        const hexAddr = '0x' + res.address.toString(16).toUpperCase();
        const isLocked = lockedAddresses.has(res.address);
        
        tr.innerHTML = `
            <td class="addr-col">${hexAddr}</td>
            <td class="val-col">${res.value}</td>
            <td class="action-cell">
                <button class="btn btn-small btn-secondary edit-btn-trigger" data-addr="${res.address}">Edit</button>
                <button class="lock-btn ${isLocked ? 'locked' : ''}" data-addr="${res.address}" data-val="${res.value}">
                    <svg viewBox="0 0 24 24">
                        ${isLocked 
                            ? '<path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"/>' 
                            : '<path d="M12 17c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm6-9h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6h1.9c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm0 12H6V10h12v10z"/>'
                        }
                    </svg>
                </button>
            </td>
        `;
        
        // Modal Trigger
        tr.querySelector('.edit-btn-trigger').addEventListener('click', () => {
            selectedAddress = res.address;
            modalAddress.textContent = hexAddr;
            modalInput.value = res.value;
            editModal.classList.remove('hidden');
        });
        
        // Lock Trigger
        tr.querySelector('.lock-btn').addEventListener('click', (e) => {
            const btn = e.currentTarget;
            const addr = parseInt(btn.dataset.addr);
            const val = btn.dataset.val;
            
            if (lockedAddresses.has(addr)) {
                lockedAddresses.delete(addr);
                sendNativeMessage({ action: 'unlock', address: addr });
            } else {
                lockedAddresses.add(addr);
                sendNativeMessage({ action: 'lock', address: addr, type: selectedType, value: val });
            }
            renderResults();
        });
        
        resultsBody.appendChild(tr);
    });
}

// Modal Buttons
btnModalCancel.addEventListener('click', () => {
    editModal.classList.add('hidden');
    selectedAddress = null;
});

btnModalSave.addEventListener('click', () => {
    const val = modalInput.value.trim();
    if (!val || selectedAddress === null) return;
    
    // Update local copy
    const idx = currentResults.findIndex(r => r.address === selectedAddress);
    if (idx !== -1) {
        currentResults[idx].value = val;
        // If locked, update locked value
        if (lockedAddresses.has(selectedAddress)) {
            sendNativeMessage({ action: 'lock', address: selectedAddress, type: selectedType, value: val });
        }
    }
    
    sendNativeMessage({
        action: 'modify',
        address: selectedAddress,
        type: selectedType,
        value: val
    });
    
    editModal.classList.add('hidden');
    selectedAddress = null;
    renderResults();
});

// Bridge callbacks from Native (C++)
window.onScanComplete = function(matchCount) {
    loader.classList.add('hidden');
    btnFirstScan.disabled = false;
    btnClear.disabled = false;
    
    if (matchCount > 0) {
        btnNextScan.disabled = false;
        statusText.textContent = `Found ${matchCount} matches`;
    } else {
        btnNextScan.disabled = true;
        statusText.textContent = "No matches found";
    }
};

window.updateResults = function(resultsJsonString) {
    try {
        currentResults = JSON.parse(resultsJsonString);
        renderResults();
    } catch (e) {
        console.error("Failed to parse results JSON:", e);
    }
};

window.updateLockedValues = function(lockedJsonString) {
    try {
        const lockedArray = JSON.parse(lockedJsonString);
        lockedAddresses = new Set(lockedArray);
        renderResults();
    } catch (e) {
        console.error("Failed to parse locked addresses JSON:", e);
    }
};
