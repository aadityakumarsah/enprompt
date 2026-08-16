/* ============ enprompt landing interactions ============ */
(function () {
  "use strict";

  /* ---------- floating cubes ---------- */
  const cubeLayer = document.getElementById("cubes");
  const CUBE_COUNT = 14;
  for (let i = 0; i < CUBE_COUNT; i++) {
    const cube = document.createElement("div");
    cube.className = "cube";
    const size = 14 + Math.random() * 40;
    cube.style.setProperty("--s", size + "px");
    cube.style.left = Math.random() * 100 + "%";
    cube.style.top = Math.random() * 100 + "%";
    cube.style.setProperty("--tx", (Math.random() * 90 - 45).toFixed(0) + "px");
    cube.style.setProperty("--ty", (Math.random() * 70 - 35).toFixed(0) + "px");
    cube.style.setProperty("--d", (6 + Math.random() * 9).toFixed(1) + "s");
    cube.style.animationDelay = (Math.random() * 4).toFixed(2) + "s";
    cube.style.opacity = (0.35 + Math.random() * 0.5).toFixed(2);
    cubeLayer.appendChild(cube);
  }

  /* ---------- reveal on scroll ---------- */
  const revealables = document.querySelectorAll(".reveal");
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
          io.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12 }
  );
  revealables.forEach((el) => io.observe(el));

  /* ---------- feature card spotlight ---------- */
  document.querySelectorAll(".feature-card").forEach((card) => {
    card.addEventListener("pointermove", (e) => {
      const rect = card.getBoundingClientRect();
      card.style.setProperty("--mx", (e.clientX - rect.left) + "px");
      card.style.setProperty("--my", (e.clientY - rect.top) + "px");
    });
  });

  /* ---------- macbook parallax tilt ---------- */
  const macbook = document.getElementById("macbook");
  if (macbook) {
    const demoSection = macbook.closest(".demo");
    demoSection.addEventListener("pointermove", (e) => {
      const rect = demoSection.getBoundingClientRect();
      const dx = (e.clientX - rect.left) / rect.width - 0.5;
      const dy = (e.clientY - rect.top) / rect.height - 0.5;
      macbook.style.transform =
        "rotateY(" + (dx * 10).toFixed(2) + "deg) rotateX(" + (-dy * 8).toFixed(2) + "deg)";
    });
    demoSection.addEventListener("pointerleave", () => {
      macbook.style.transform = "rotateY(0deg) rotateX(0deg)";
    });
  }

  /* ---------- rotating hero word ---------- */
  const words = ["thought", "lightning", "perfection", "magic", "you"];
  const el = document.getElementById("typeword");
  let wordIndex = 0;
  let charIndex = words[0].length;
  let deleting = false;

  function typeLoop() {
    if (!el) return;
    const word = words[wordIndex];
    if (!deleting) {
      charIndex++;
      if (charIndex > word.length) {
        deleting = true;
        setTimeout(typeLoop, 1800);
        return;
      }
    } else {
      charIndex--;
      if (charIndex === 0) {
        deleting = false;
        wordIndex = (wordIndex + 1) % words.length;
      }
    }
    el.textContent = word.slice(0, charIndex);
    setTimeout(typeLoop, deleting ? 42 : 95);
  }
  typeLoop();


  /* ---------- copy install command ---------- */
  const installCmd = document.getElementById("install-cmd");
  const copied = document.getElementById("install-copied");
  function copyInstallCommand(btn, feedbackText) {
    if (!installCmd) return;
    const done = () => {
      const original = btn.innerHTML;
      btn.innerHTML = feedbackText || "Copied!";
      setTimeout(() => { btn.innerHTML = original; }, 2200);
      if (copied) {
        copied.hidden = false;
        setTimeout(() => { copied.hidden = true; }, 2200);
      }
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(installCmd.textContent.trim()).then(done).catch(done);
    } else {
      done();
    }
  }
  const heroCopyBtn = document.getElementById("hero-copy-btn");
  if (heroCopyBtn) {
    heroCopyBtn.addEventListener("click", () => copyInstallCommand(heroCopyBtn, "Copied! Paste in Terminal"));
  }
  const copyBtn = document.getElementById("copy-install-btn");
  if (copyBtn) {
    copyBtn.addEventListener("click", () => copyInstallCommand(copyBtn));
  }

  /* ---------- nav blur on scroll ---------- */
  const nav = document.querySelector(".nav");
  window.addEventListener("scroll", () => {
    nav.style.background =
      window.scrollY > 12
        ? "rgba(253, 250, 246, 0.92)"
        : "rgba(253, 250, 246, 0.75)";
  });
})();