var convertTime = function() {
  /* Convert UTC times to local browser times
  *  Requires that the times on the server are UTC
  *  Requires a class name of `time` to be set on element desired to be changed
  *  Requires that element has an attribute `epoch` containing the seconds since
  *  1.1.1970 UTC.
  */
  $('.time').each(function() {
    var content = $(this).text();
    if(content === 'never' || content === 'unknown' || content === '') {
      return;
    }
    var epoch = $(this).attr('epoch');
    if(epoch === undefined) {
      return;
    }
    var utcTime = Number(epoch);
    var dj = dayjs.unix(utcTime).local();

    $(this).text(dj.format('YYYY-MM-DD HH:mm:ss [(UTC]Z[)]'));
  });
};

$(function() {
  if ($.fn.dataTable && $.fn.dataTable.ext && window.Intl && Intl.Collator) {
    var versionCollator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
    $.fn.dataTable.ext.type.order['version-sort-pre'] = function(value) {
      return value === 'Unknown' ? '' : value;
    };
    $.fn.dataTable.ext.type.order['version-sort-asc'] = function(left, right) {
      return versionCollator.compare(left, right);
    };
    $.fn.dataTable.ext.type.order['version-sort-desc'] = function(left, right) {
      return versionCollator.compare(right, left);
    };
    $.fn.dataTable.ext.type.order['ip-sort-pre'] = function(value) {
      var address = String(value).trim();
      var octets = address.split('.');
      if (octets.length === 4 && octets.every(function(octet) { return /^\d+$/.test(octet) && Number(octet) <= 255; })) {
        return octets.map(function(octet) { return String(Number(octet)).padStart(3, '0'); }).join('.');
      }
      return address.toLowerCase();
    };
  }

  convertTime();

  // Reloads the nodes from a source by calling the protected /reload.json URI
  $('#reload').click(function() {
    $.post(window.location.pathname.replace(/nodes.*/g, '')+'reload.json')
      .done(function(data) {
        $('#flashMessage')
        .removeClass('alert-danger')
        .addClass('alert-success')
        .text(data);
      })
      .fail(function() {
        var data = 'Unable to reload nodes'
        $('#flashMessage')
          .removeClass('alert-success')
          .addClass('alert-danger')
          .text(data);
      })
      .always(function() {
        $('#flashMessage').removeClass('hidden');
      });
  });

  // Update timestamp on next button click for DataTables
  $('.paginate_button').on('click', function() {
    convertTime();
  });
});
