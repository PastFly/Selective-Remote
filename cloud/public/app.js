const status = document.querySelector("#service-status");
try {
  const response = await fetch("/v1/meta", { headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error("unavailable");
  const meta = await response.json();
  status.textContent = `API v${meta.apiVersion} · сервис доступен`;
  status.classList.add("ok");
} catch {
  status.textContent = "Сервис недоступен";
}
