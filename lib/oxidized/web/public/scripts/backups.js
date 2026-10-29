/* Manual configuration collection. Status comes from Core, never from Git counts. */
document.addEventListener('DOMContentLoaded', function () {
  var panel = document.getElementById('backup-progress');
  if (!panel) return;
  var endpoint = panel.dataset.endpoint;
  var tracked = [];
  var pending = false;
  try { tracked = JSON.parse(sessionStorage.getItem('oxidized-backups') || '[]'); } catch (_) {}
  if (!Array.isArray(tracked)) tracked = [];
  function message(text) {
    panel.hidden = false;
    document.getElementById('backup-summary').textContent = text;
  }
  async function request(body) {
    var options = {headers: {'Accept': 'application/json'}};
    if (body) {
      options.method = 'POST'; options.body = body;
      options.headers['X-CSRF-Token'] = panel.dataset.csrf;
    }
    var response = await fetch(endpoint, options);
    if (!(response.headers.get('Content-Type') || '').includes('application/json')) {
      throw new Error('Backup request could not be verified. Refresh the page and sign in again.');
    }
    var data = await response.json();
    if (!response.ok) throw new Error(data.error || 'Backup request failed. Please sign in again.');
    return data.devices;
  }
  function render(devices) {
    var rows = tracked.map(function (name) {
      return devices.find(function (node) { return node.name === name; }) || {name: name, state: 'unknown'};
    });
    var counts = {queued: 0, running: 0, succeeded: 0, failed: 0, unknown: 0};
    rows.forEach(function (row) {
      var state = row.state === 'success' ? 'succeeded' : row.state;
      counts[state in counts ? state : 'unknown']++;
    });
    var complete = counts.succeeded + counts.failed;
    message('Total ' + rows.length + ' · Queued ' + counts.queued + ' · Running ' + counts.running +
      ' · Succeeded ' + counts.succeeded + ' · Failed ' + counts.failed + ' · Completed ' + complete +
      (counts.unknown ? ' · Tracking unavailable for ' + counts.unknown + ' (service restart or inventory change).' : ''));
    var meter = document.getElementById('backup-meter'); meter.max = rows.length || 1; meter.value = complete;
    var list = document.getElementById('backup-results'); list.replaceChildren();
    rows.forEach(function (row) {
      var item = document.createElement('li');
      var state = row.state === 'not_requested' ? 'tracking unavailable after restart' : row.state;
      var reasons = {no_connection: 'Connection could not be established', no_auth: 'Authentication failed',
        timelimit: 'Collection exceeded the time limit', fail: 'Core reported a collection failure'};
      item.textContent = row.name + ': ' + state + (row.result && row.state === 'failed' ? ' — ' + (reasons[row.result] || row.result) : '') +
        (row.last_attempt_at ? (row.state === 'succeeded' ? ' · Last successful collection: ' : ' · Last attempt: ') + new Date(row.last_attempt_at).toLocaleString() : '');
      list.appendChild(item);
    });
    document.querySelectorAll('form[action*="/node/next/"]').forEach(function (form) {
      var encodedName = form.action.split('/').pop();
      var name;
      try { name = decodeURIComponent(encodedName); } catch (_) { name = encodedName; }
      var row = devices.find(function (node) { return node.name === name || node.full_name === name; });
      var button = form.querySelector('button');
      if (button) {
        var active = !!row && ['queued', 'running'].includes(row.state);
        button.disabled = active || pending;
        button.title = active ? 'A configuration backup is already ' + row.state + ' for this device' : 'Queue a configuration backup through Oxidized Core';
        button.setAttribute('aria-busy', String(active));
      }
    });
    return devices.some(function (node) { return ['queued', 'running'].includes(node.state); });
  }
  var timer;
  async function poll() {
    try { if (tracked.length && render(await request())) timer = setTimeout(poll, 2000); }
    catch (error) { message(error.message); }
  }
  async function discoverActiveJobs() {
    try {
      var devices = await request();
      tracked = devices.filter(function (node) { return ['queued', 'running'].includes(node.state); }).map(function (node) { return node.name; });
      if (!tracked.length) return;
      render(devices);
      timer = setTimeout(poll, 2000);
    } catch (_) { /* The action remains available; queue responses still verify auth and Core support. */ }
  }
  async function queue(names, all) {
    if (pending) return;
    pending = true;
    try {
      if (all) {
        var devices = await request();
        if (!confirm('Queue configuration backups for all ' + devices.length + ' devices?')) return;
      }
      var body = new URLSearchParams();
      if (all) body.set('all', 'true');
      else names.forEach(function (name) { body.append('devices[]', name); });
      message('Requesting configuration collection…');
      var result = await request(body);
      tracked = result.map(function (node) { return node.name; });
      try { sessionStorage.setItem('oxidized-backups', JSON.stringify(tracked)); } catch (_) {}
      clearTimeout(timer); render(result); timer = setTimeout(poll, 1000);
    } catch (error) { message(error.message); }
    finally { pending = false; }
  }
  document.querySelectorAll('.backup-all').forEach(function (button) {
    button.addEventListener('click', function () { queue([], true); });
  });
  document.addEventListener('submit', function (event) {
    var form = event.target;
    if (!form.matches('form[action*="/node/next/"]')) return;
    event.preventDefault(); queue([decodeURIComponent(form.action.split('/').pop())], false);
  });
  var bulk = document.getElementById('bulkDevices');
  if (bulk) bulk.addEventListener('submit', function (event) {
    if (event.defaultPrevented) return;
    if (document.getElementById('bulkOperation').value !== 'backup') return;
    event.preventDefault();
    var inputs = window.jQuery && jQuery.fn.dataTable.isDataTable('#managedDevices') ?
      jQuery('#managedDevices').DataTable().$('input.device-selection:checked').toArray() :
      Array.from(document.querySelectorAll('.device-selection:checked'));
    queue(inputs.map(function (input) { return input.value; }), false);
  });
  if (tracked.length) poll(); else discoverActiveJobs();
});
