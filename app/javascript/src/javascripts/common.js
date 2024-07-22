import Cookie from "./cookie";
import LS from "./local_storage";
import Utility from "./utility";

function initSearch () {
  const $searchForm = $("#searchform");
  const $searchShow = $("#search-form-show-link");
  const $searchHide = $("#search-form-hide-link");
  if ($searchForm.length) {
    $searchShow.on("click", e => {
      e.preventDefault();
      $searchForm.fadeIn("fast");
      $searchShow.hide();
      $searchHide.show();
    });
    $searchHide.on("click", e => {
      e.preventDefault();
      $searchForm.fadeOut("fast");
      $searchShow.show();
      $searchHide.hide();
    });
  }
}

$(function () {
  $("#theme-switcher").change(function () {
    let theme = $(this).val();
    LS.put("theme", theme);
    $("body").attr("data-th-main", theme);
  });

  {
    let theme = LS.get("theme") || "none";
    $("body").attr("data-th-main", theme);
    $("#theme-switcher").val(theme);
  }

  // Account notices
  $("#hide-dmail-notice").on("click.danbooru", function (e) {
    e.preventDefault();
    const $notice = $("#dmail-notice");
    $notice.hide();
    const id = $notice.data("id");
    Cookie.put("hide_dmail_notice", id);
  });

  $("#hide-notification-notice").on("click.danbooru", function (e) {
    e.preventDefault();
    const $notice = $("#notification-notice");
    $notice.hide();
    const id = $notice.data("id");
    Cookie.put("hide_notification_notice", id);
  });

  $("#close-notice-link").on("click.danbooru", function (e) {
    $("#notice").fadeOut("fast");
    e.preventDefault();
  });

  $(".revert-item-link").on("click", e => {
    e.preventDefault();
    const target = $(e.target);
    const noun = target.data("noun");
    if (!confirm(`Are you sure you want to revert ${noun} to this version?`))
      return;
    const path = target.attr("href");
    $.ajax({
      method: "PUT",
      url: path,
      dataType: "json",
    }).done(() => {
      location.reload();
    }).fail(() => {
      Utility.error("Failed to revert to specified version.");
    });
  });

  initSearch();
});

window.submitInvisibleRecaptchaForm = function () {
  document.getElementById("signup-form").submit();
};
