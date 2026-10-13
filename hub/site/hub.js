// Lists the apps from apps.json and probes each one's /<id>/version.json (written into every app
// image by docker/app.Dockerfile) to show whether it is deployed and which version runs.
(async () => {
  const main = document.getElementById("apps");
  const tpl = document.getElementById("card").content;
  const apps = (await (await fetch("apps.json", { cache: "no-cache" })).json()).apps;
  let up = 0;

  const probe = async (app, card) => {
    const status = card.querySelector(".status");
    try {
      const r = await fetch(`${app.id}/version.json`, { cache: "no-cache" });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const v = await r.json();
      status.className = "status ok";
      status.title = `running ${v.version}${v.sha ? ` (${v.sha.slice(0, 7)})` : ""}`;
      const ver = document.createElement("span");
      ver.className = "version";
      ver.textContent = v.version;
      card.querySelector(".name").append(ver);
      up++;
    } catch (e) {
      status.className = "status down";
      status.title = `not running (${e.message})`;
      card.classList.add("down");
    }
  };

  const probes = apps.map((app) => {
    const card = tpl.cloneNode(true).firstElementChild;
    card.href = `${app.id}/`;
    card.style.setProperty("--app", app.color);
    card.querySelector(".mark").textContent = app.name.replace(/[^A-Z]/g, "").slice(0, 2) || app.name[0];
    card.querySelector(".name").textContent = app.name;
    card.querySelector(".tagline").textContent = app.tagline;
    main.append(card);
    return probe(app, card);
  });
  await Promise.all(probes);
  document.getElementById("summary").textContent = `${up} of ${apps.length} apps running`;
})();
