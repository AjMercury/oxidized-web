(function() {
  'use strict';

  document.addEventListener('DOMContentLoaded', function() {
    var viewer = document.getElementById('configViewer');
    var source = document.getElementById('configSource');
    if (!viewer || !source) return;

    var originalText = source.textContent;
    var lines = originalText.split(/\r?\n/);
    if (originalText.endsWith('\n') || originalText.endsWith('\r')) lines.pop();
    if (!lines.length) lines.push('');

    var stage = document.createElement('div');
    stage.className = 'config-virtual-content';
    viewer.replaceChildren(stage);

    var wrapButton = document.getElementById('configWrap');
    var searchInput = document.getElementById('configSearch');
    var searchCount = document.getElementById('configSearchCount');
    var lineCount = document.getElementById('configLineCount');
    var feedback = document.getElementById('configFeedback');
    var wrap = false;
    var query = '';
    var matches = [];
    var activeMatch = -1;
    var lineHeight = 22;
    var characterWidth = 8;
    var positions = [];
    var heights = [];
    var totalHeight = 0;
    var renderFrame = 0;

    if (lineCount) lineCount.textContent = lines.length + ' lines';

    function measureCharacter() {
      var canvas = document.createElement('canvas');
      var context = canvas.getContext('2d');
      if (context) {
        var styles = window.getComputedStyle(viewer);
        context.font = styles.fontSize + ' ' + styles.fontFamily;
        characterWidth = context.measureText('0').width || characterWidth;
      }
    }

    function measureLines() {
      measureCharacter();
      lineHeight = parseFloat(window.getComputedStyle(viewer).lineHeight) || 22;
      var columns = Math.max(24, Math.floor((viewer.clientWidth - 72) / characterWidth));
      positions = new Array(lines.length);
      heights = new Array(lines.length);
      totalHeight = 0;
      var longest = 0;
      lines.forEach(function(line, index) {
        positions[index] = totalHeight;
        var lineRows = wrap ? Math.max(1, Math.ceil(line.length / columns)) : 1;
        heights[index] = lineRows * lineHeight;
        totalHeight += heights[index];
        longest = Math.max(longest, line.length);
      });
      stage.style.height = Math.max(totalHeight, viewer.clientHeight) + 'px';
      stage.style.width = wrap ? '100%' : Math.max(viewer.clientWidth, longest * characterWidth + 72) + 'px';
    }

    function lowerBound(value) {
      var low = 0;
      var high = positions.length;
      while (low < high) {
        var middle = (low + high) >> 1;
        if (positions[middle] + heights[middle] < value) low = middle + 1;
        else high = middle;
      }
      return low;
    }

    function appendHighlighted(target, text, term) {
      if (!term) {
        target.textContent = text;
        return;
      }
      var lowerText = text.toLocaleLowerCase();
      var lowerTerm = term.toLocaleLowerCase();
      var cursor = 0;
      var found = lowerText.indexOf(lowerTerm, cursor);
      while (found !== -1) {
        target.appendChild(document.createTextNode(text.slice(cursor, found)));
        var mark = document.createElement('mark');
        mark.textContent = text.slice(found, found + term.length);
        target.appendChild(mark);
        cursor = found + term.length;
        found = lowerText.indexOf(lowerTerm, cursor);
      }
      target.appendChild(document.createTextNode(text.slice(cursor)));
    }

    function render() {
      renderFrame = 0;
      if (!positions.length) return;
      var overscan = 12 * lineHeight;
      var start = Math.max(0, lowerBound(Math.max(0, viewer.scrollTop - overscan)) - 1);
      var end = Math.min(lines.length, lowerBound(viewer.scrollTop + viewer.clientHeight + overscan) + 2);
      stage.replaceChildren();
      for (var index = start; index < end; index += 1) {
        var row = document.createElement('div');
        row.className = 'config-line';
        if (matches.indexOf(index) !== -1) row.classList.add('config-line-match');
        if (index === matches[activeMatch]) row.classList.add('config-line-active-match');
        row.style.top = positions[index] + 'px';
        row.style.height = heights[index] + 'px';

        var number = document.createElement('span');
        number.className = 'config-line-number';
        number.textContent = String(index + 1);
        number.setAttribute('aria-hidden', 'true');

        var content = document.createElement('code');
        content.className = 'config-line-content';
        appendHighlighted(content, lines[index], query);
        if (wrap) content.classList.add('is-wrapped');

        row.appendChild(number);
        row.appendChild(content);
        stage.appendChild(row);
      }
    }

    function requestRender() {
      if (renderFrame) return;
      renderFrame = window.requestAnimationFrame(render);
    }

    function scrollToMatch(direction) {
      if (!matches.length) return;
      activeMatch = (activeMatch + direction + matches.length) % matches.length;
      viewer.scrollTop = positions[matches[activeMatch]];
      requestRender();
    }

    function updateSearch() {
      query = searchInput ? searchInput.value : '';
      matches = [];
      activeMatch = -1;
      if (query) {
        var normalized = query.toLocaleLowerCase();
        lines.forEach(function(line, index) {
          if (line.toLocaleLowerCase().indexOf(normalized) !== -1) matches.push(index);
        });
      }
      if (searchCount) searchCount.textContent = query ? matches.length + ' matching lines' : '';
      if (matches.length) {
        activeMatch = 0;
        viewer.scrollTop = positions[matches[0]];
      }
      requestRender();
    }

    function copyConfiguration() {
      function announce(message) { if (feedback) feedback.textContent = message; }
      function fallbackCopy() {
        var textarea = document.createElement('textarea');
        textarea.value = originalText;
        textarea.setAttribute('readonly', '');
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        var copied = document.execCommand('copy');
        textarea.remove();
        announce(copied ? 'Configuration copied.' : 'Clipboard access is unavailable in this browser.');
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(originalText).then(function() {
          announce('Configuration copied.');
        }).catch(fallbackCopy);
      } else fallbackCopy();
    }

    function setFullscreen(enabled) {
      var button = document.getElementById('configFullscreen');
      document.getElementById('configurationWorkspace').classList.toggle('config-viewer-fullscreen', enabled);
      if (button) {
        button.setAttribute('aria-pressed', String(enabled));
        button.innerHTML = enabled
          ? '<i class="bi bi-fullscreen-exit" aria-hidden="true"></i> Exit full screen'
          : '<i class="bi bi-arrows-fullscreen" aria-hidden="true"></i> Full screen';
      }
    }

    measureLines();
    render();
    viewer.addEventListener('scroll', requestRender, { passive: true });
    window.addEventListener('resize', function() { measureLines(); requestRender(); });
    if (window.ResizeObserver) {
      new ResizeObserver(function() { measureLines(); requestRender(); }).observe(viewer);
    }
    if (searchInput) searchInput.addEventListener('input', updateSearch);
    document.getElementById('configPrevMatch').addEventListener('click', function() { scrollToMatch(-1); });
    document.getElementById('configNextMatch').addEventListener('click', function() { scrollToMatch(1); });
    document.getElementById('configCopy').addEventListener('click', copyConfiguration);
    if (wrapButton) wrapButton.addEventListener('click', function() {
      wrap = !wrap;
      wrapButton.setAttribute('aria-pressed', String(wrap));
      viewer.classList.toggle('config-word-wrap', wrap);
      measureLines();
      requestRender();
    });
    document.getElementById('configFullscreen').addEventListener('click', function() {
      setFullscreen(!document.getElementById('configurationWorkspace').classList.contains('config-viewer-fullscreen'));
    });
    document.addEventListener('keydown', function(event) {
      if (event.key === 'Escape') setFullscreen(false);
      if (event.key === 'Enter' && document.activeElement === searchInput && matches.length) {
        scrollToMatch(event.shiftKey ? -1 : 1);
      }
    });
  });
})();
