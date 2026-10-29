(function() {
  'use strict';

  document.addEventListener('DOMContentLoaded', function() {
    function readPreference(key) {
      try { return window.localStorage.getItem(key); } catch (_error) { return null; }
    }
    function writePreference(key, value) {
      try { window.localStorage.setItem(key, value); } catch (_error) { /* storage may be disabled */ }
    }
    var counters = document.querySelectorAll('[data-counter]');
    var motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)');
    counters.forEach(function(counter) {
      var target = Number(counter.getAttribute('data-counter'));
      if (!Number.isFinite(target)) return;
      if (motionPreference.matches) {
        counter.textContent = String(target);
        return;
      }
      var start = performance.now();
      var duration = 520;
      function tick(now) {
        var progress = Math.min((now - start) / duration, 1);
        var eased = 1 - Math.pow(1 - progress, 3);
        counter.textContent = String(Math.round(target * eased));
        if (progress < 1) window.requestAnimationFrame(tick);
      }
      window.requestAnimationFrame(tick);
    });

    var toggle = document.getElementById('sidebar-toggle');
    var sidebar = document.getElementById('app-sidebar');
    if (!toggle || !sidebar) return;

    var collapseToggle = document.getElementById('sidebar-collapse-toggle');
    var isMobileViewport = function() { return window.matchMedia('(max-width: 991.98px)').matches; };

    if (collapseToggle) {
      var collapsed = readPreference('oxidized-sidebar-collapsed') === 'true';
      document.body.classList.toggle('sidebar-collapsed', collapsed && !isMobileViewport());
      collapseToggle.setAttribute('aria-pressed', String(collapsed));
      collapseToggle.setAttribute('aria-label', collapsed ? 'Expand sidebar' : 'Collapse sidebar');
      collapseToggle.title = collapsed ? 'Expand sidebar' : 'Collapse sidebar';
      collapseToggle.addEventListener('click', function() {
        var nowCollapsed = document.body.classList.toggle('sidebar-collapsed');
        writePreference('oxidized-sidebar-collapsed', String(nowCollapsed));
        collapseToggle.setAttribute('aria-pressed', String(nowCollapsed));
        collapseToggle.setAttribute('aria-label', nowCollapsed ? 'Expand sidebar' : 'Collapse sidebar');
        collapseToggle.title = nowCollapsed ? 'Expand sidebar' : 'Collapse sidebar';
      });
    }

    function syncSidebarVisibility(isOpen) {
      var isMobile = isMobileViewport();
      sidebar.setAttribute('aria-hidden', String(isMobile && !isOpen));
      sidebar.inert = isMobile && !isOpen;
    }

    function closeSidebar() {
      document.body.classList.remove('sidebar-open');
      toggle.setAttribute('aria-expanded', 'false');
      toggle.setAttribute('aria-label', 'Open navigation');
      syncSidebarVisibility(false);
    }

    toggle.addEventListener('click', function() {
      var isOpen = document.body.classList.toggle('sidebar-open');
      toggle.setAttribute('aria-expanded', String(isOpen));
      toggle.setAttribute('aria-label', isOpen ? 'Close navigation' : 'Open navigation');
      syncSidebarVisibility(isOpen);
      if (isOpen) sidebar.querySelector('a').focus();
    });

    syncSidebarVisibility(false);
    window.addEventListener('resize', function() {
      document.body.classList.toggle('sidebar-collapsed',
        readPreference('oxidized-sidebar-collapsed') === 'true' && !isMobileViewport());
      syncSidebarVisibility(document.body.classList.contains('sidebar-open'));
    });

    document.addEventListener('keydown', function(event) {
      if (event.key === 'Escape' && document.body.classList.contains('sidebar-open')) {
        closeSidebar();
        toggle.focus();
      }
    });

    document.addEventListener('click', function(event) {
      if (document.body.classList.contains('sidebar-open') &&
          !sidebar.contains(event.target) && !toggle.contains(event.target)) {
        closeSidebar();
      }
    });
  });
})();
