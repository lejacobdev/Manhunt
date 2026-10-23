// Menu toggle for the phone nav, and the gentle reveal as sections scroll in. The site works
// fully without this file.
document.documentElement.classList.add("js");
const nav = document.querySelector(".nav");
const btn = document.querySelector(".menu-btn");
if (nav && btn) {
  btn.addEventListener("click", () => {
    const open = nav.dataset.open !== "true";
    nav.dataset.open = String(open);
    btn.setAttribute("aria-expanded", String(open));
  });
  nav.querySelectorAll(".links a").forEach((a) => a.addEventListener("click", () => { nav.dataset.open = "false"; btn.setAttribute("aria-expanded", "false"); }));
}
if ("IntersectionObserver" in window && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
  const io = new IntersectionObserver((entries) => entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } }), { rootMargin: "0px 0px -8% 0px" });
  document.querySelectorAll(".reveal").forEach((el) => io.observe(el));
} else {
  document.querySelectorAll(".reveal").forEach((el) => el.classList.add("in"));
}
