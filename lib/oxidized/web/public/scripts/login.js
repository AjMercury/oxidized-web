document.addEventListener('DOMContentLoaded', function () {
  var password = document.getElementById('password');
  var toggle = document.getElementById('togglePassword');
  var form = document.getElementById('loginForm');
  var submit = document.getElementById('loginSubmit');
  if (toggle && password) {
    toggle.addEventListener('click', function () {
      var visible = password.type === 'password';
      password.type = visible ? 'text' : 'password';
      toggle.setAttribute('aria-pressed', String(visible));
      toggle.setAttribute('aria-label', visible ? 'Hide password' : 'Show password');
      var icon = toggle.querySelector('i');
      if (icon) icon.className = visible ? 'bi bi-eye-slash' : 'bi bi-eye';
    });
  }
  if (form && submit) {
    form.addEventListener('submit', function () {
      submit.disabled = true;
      submit.classList.add('is-loading');
      submit.setAttribute('aria-busy', 'true');
    });
  }
});
