/* The landing page's one flourish: the word "boring" cycling through the
   languages, to prove the claim in the sentence it sits in.

   Initialised from frontend/index.js only on body.welcome.index.

   The word is absolutely positioned inside .rotbox, so the BOX's width is the
   gap between "Now" and "in". Animating that width is what makes the two
   neighbouring words slide in and out to meet each word as it arrives, instead
   of standing at a fixed distance sized for the longest word. */
const Homepage = {
  words: [ "boring", "langweilig", "aburrido", "مملمُمِلّ" , "saai"],

  CYCLE: 6400,      // one full breath — fade out, swap, fade in — in ms
  HOLD: 0.10,       // fraction of the cycle held invisible at the trough
  // How far THROUGH each fade the slide starts and ends — not a time, which
  // nobody can picture, but a point in the fade you can see.
  //   2/3 = begins when the old word is two thirds gone,
  //         ends when the new word is two thirds arrived
  // It straddles the invisible trough, so both ends are hidden in the faint
  // part of the fade and only the middle of the movement is visible.
  SLIDE_AT: 2 / 3,

  init() {
    this.word = document.getElementById("rot");
    if (!this.word) return;

    this.box       = this.word.parentElement;
    this.index     = 0;
    this.swapped   = false;
    this.startedAt = null;
    this.tick      = this.tick.bind(this);

    // Measure only once the real font has arrived. The faces are self-hosted and
    // load asynchronously, so measuring immediately measures the FALLBACK font
    // and every width and ink offset is quietly wrong.
    const ready = document.fonts ? document.fonts.ready : Promise.resolve();

    ready.then(() => {
      this.widths = this.measureWords();
      this.place(0);

      // A reader who asked for less motion gets the sentence, not the trick.
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

      requestAnimationFrame(this.tick);
    });
  },

  /* Each word measured against the real font, twice over:

       width  — the advance width, which is what the box has to be
       shift  — how far the INK sits from the middle of that width

     An italic face leans right, so its ink is not centred in its own advance
     width. The box centres perfectly and the word still looks pushed towards
     the word on its right. canvas measureText reports the ink bounds, so the
     correction is measured per word rather than nudged by hand. */
  measureWords() {
    const style = getComputedStyle(this.word);
    const ctx = document.createElement("canvas").getContext("2d");

    ctx.font = [ style.fontStyle, style.fontWeight, style.fontSize, style.fontFamily ].join(" ");

    return this.words.map((word) => {
      const m = ctx.measureText(word);
      const inkLeft  = m.actualBoundingBoxLeft;
      const inkRight = m.actualBoundingBoxRight;
      const usable   = Number.isFinite(inkLeft) && Number.isFinite(inkRight);

      return {
        width: m.width,
        shift: usable ? m.width / 2 - (inkRight - inkLeft) / 2 : 0
      };
    });
  },

  /* Ease in and out, 0 → 1. The same curve drives the fade and the slide, which
     is what makes them read as one movement rather than two. */
  ease(progress) {
    const p = Math.min(Math.max(progress, 0), 1);
    return (1 - Math.cos(p * Math.PI)) / 2;
  },

  tick(now) {
    if (this.startedAt === null) this.startedAt = now;

    const t       = ((now - this.startedAt) % this.CYCLE) / this.CYCLE;
    const fadeEnd = 0.5 - this.HOLD / 2;
    const holdEnd = 0.5 + this.HOLD / 2;

    // A new breath begins: lock the two widths this one travels between. They
    // have to be captured now, because the slide outlives the swap that changes
    // this.index halfway through it.
    if (this.lastT === undefined || t < this.lastT) {
      const next = (this.index + 1) % this.words.length;
      this.slideFrom = this.widths[this.index].width;
      this.slideTo   = this.widths[next].width;
      this.swapped   = false;
    }
    this.lastT = t;

    if (t < fadeEnd) {
      this.word.style.opacity = (1 - this.ease(t / fadeEnd)).toFixed(3);
    } else if (t < holdEnd) {
      this.word.style.opacity = "0";

      if (!this.swapped) {
        this.index = (this.index + 1) % this.words.length;
        this.word.textContent = this.words[this.index];
        this.word.style.transform = `translateX(${this.widths[this.index].shift.toFixed(2)}px)`;
        this.swapped = true;
      }
    } else {
      this.word.style.opacity = this.ease((t - holdEnd) / (1 - holdEnd)).toFixed(3);
    }

    // The slide runs across all three phases, so it is applied outside them.
    const reach = this.easeInverse(this.SLIDE_AT);
    const from  = reach * fadeEnd;
    const to    = holdEnd + reach * (1 - holdEnd);
    this.setWidth(this.slideFrom, this.slideTo, this.ease((t - from) / (to - from)));

    requestAnimationFrame(this.tick);
  },

  /* How far into a fade a given amount of it has happened — the inverse of
     ease(), so the slide can be placed by what you see rather than by a clock. */
  easeInverse(value) {
    return Math.acos(1 - 2 * value) / Math.PI;
  },

  /* Fractional pixels on purpose. Rounding meant that over a long, short
     journey consecutive frames landed on the same integer and then jumped a
     whole pixel — a slide that stepped instead of moving. */
  setWidth(from, to, progress) {
    this.box.style.width = `${(from + (to - from) * progress).toFixed(2)}px`;
  },

  /* Width of the box, and the word's own correction inside it. */
  place(index) {
    this.box.style.width = `${this.widths[index].width.toFixed(2)}px`;
    this.word.style.transform = `translateX(${this.widths[index].shift.toFixed(2)}px)`;
  }
};

export default Homepage;
