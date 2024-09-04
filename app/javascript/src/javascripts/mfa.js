import Utility from "./utility";

class MFA {
  static init () {
    $(".show-code-link").on("click", function () {
      $(this).parent().find(".mfa-code").show();
      $(this).hide();
    });
  }

  static init_backup_codes (mfaBackupCodes) {
    $(".print-backup-codes-link").on("click", function (event) {
      event.preventDefault();
      Utility.printPage("/users/mfa/backup_codes.txt");
    });
    $(".copy-backup-codes-link").on("click", function (event) {
      event.preventDefault();
      Utility.copyToClipboard(mfaBackupCodes);
    });
  }
}

$(function () {
  if ($("#c-users-mfa #a-edit")) {
    MFA.init();
  }
});

export default MFA;
