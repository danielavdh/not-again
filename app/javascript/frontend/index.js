/* The PUBLIC side of the app — the front page, the legal pages, the demo.
   Everything behind a login is accounting.js instead.

   Loaded by application.js, which waits for both DOMContentLoaded and window
   load before calling initFrontend, so anything in here can assume the DOM. */
import { setupFlashMessages, toggleLanguageBar } from "scripts/utils";
import Homepage from "frontend/homepage";

const frontend = {
  initFrontend() {
    /* for small screens, to click away flash messages */
    setupFlashMessages();
    toggleLanguageBar();

    if (document.querySelector('body.welcome.index')) Homepage.init();
  }
};

export default frontend;
