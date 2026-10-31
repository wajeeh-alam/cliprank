const revealItems = document.querySelectorAll(".reveal");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

if (reducedMotion || !("IntersectionObserver" in window)) {
  revealItems.forEach((item) => item.classList.add("visible"));
} else {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12 });
  revealItems.forEach((item) => observer.observe(item));
}

const runButton = document.querySelector("#run-demo");
const consolePanel = document.querySelector(".pipeline-console");
const consoleState = document.querySelector("#console-state");
const stages = [...document.querySelectorAll("#pipeline-stages li")];
const toast = document.querySelector("#demo-toast");
let demoRunning = false;

const wait = (duration) => new Promise((resolve) => window.setTimeout(resolve, duration));

async function runSamplePipeline() {
  if (demoRunning) return;
  demoRunning = true;
  runButton.disabled = true;
  runButton.querySelector("span:first-child").textContent = "Processing sample…";
  consolePanel.classList.remove("complete");
  consolePanel.classList.add("running");
  consoleState.textContent = "RUNNING";
  stages.forEach((stage) => stage.classList.remove("active", "done"));
  consolePanel.scrollIntoView({ behavior: reducedMotion ? "auto" : "smooth", block: "center" });

  for (const stage of stages) {
    stage.classList.add("active");
    await wait(reducedMotion ? 50 : 620);
    stage.classList.remove("active");
    stage.classList.add("done");
  }

  consolePanel.classList.remove("running");
  consolePanel.classList.add("complete");
  consoleState.textContent = "COMPLETE";
  runButton.disabled = false;
  runButton.querySelector("span:first-child").textContent = "Replay the sample pipeline";
  toast.classList.add("visible");
  await wait(1900);
  toast.classList.remove("visible");
  document.querySelector("#results").scrollIntoView({ behavior: reducedMotion ? "auto" : "smooth" });
  demoRunning = false;
}

runButton.addEventListener("click", runSamplePipeline);

document.querySelectorAll("video").forEach((video) => {
  video.addEventListener("play", () => {
    document.querySelectorAll("video").forEach((otherVideo) => {
      if (otherVideo !== video) otherVideo.pause();
    });
  });
});
