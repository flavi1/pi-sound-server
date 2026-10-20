<?php
// Page d'accueil de la Pi : http://hifi.local/
// Ce dossier (www/ du dépôt pi-sound-server) est déployé à chaque mise à jour dans
// /var/www/hifi : remplacez ou complétez librement (PHP, HTML, CSS…).
$host = preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? gethostname());
$h = htmlspecialchars($host, ENT_QUOTES);
$liens = [];
if (is_dir('/var/www/rompr-web/rompr')) {
    $liens[] = ['/rompr/', 'Musique', 'Bibliothèque, file de lecture, radios (RompR)'];
}
$liens[] = ["http://$h:8080/", 'Fichiers', 'Disques branchés sur la Pi, en lecture (si le serveur de données est installé)'];
?><!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars(gethostname(), ENT_QUOTES) ?></title>
<style>
  :root { --fond: #f6f4ef; --texte: #1d1d1b; --doux: #6b6860; --carte: #fff; --accent: #8a3b12; }
  @media (prefers-color-scheme: dark) {
    :root { --fond: #171614; --texte: #ece9e2; --doux: #a19d93; --carte: #22201d; --accent: #e08a55; }
  }
  body { margin: 0; background: var(--fond); color: var(--texte);
         font: 17px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 40rem; margin: 0 auto; padding: 3rem 1rem; }
  h1 { font-size: 2rem; margin: 0 0 .25rem; }
  p.sous { color: var(--doux); margin: 0 0 2rem; }
  a.carte { display: block; background: var(--carte); color: inherit; text-decoration: none;
            border-radius: 12px; padding: 1rem 1.25rem; margin-bottom: .75rem;
            border: 1px solid color-mix(in srgb, var(--doux) 25%, transparent); }
  a.carte:hover { border-color: var(--accent); }
  a.carte strong { color: var(--accent); font-size: 1.1rem; }
  a.carte span { display: block; color: var(--doux); font-size: .95rem; }
  footer { color: var(--doux); font-size: .85rem; margin-top: 2rem; }
</style>
</head>
<body>
<main>
  <h1>Bienvenue</h1>
  <p class="sous">Serveur de son <?= htmlspecialchars(gethostname(), ENT_QUOTES) ?></p>
<?php foreach ($liens as [$url, $titre, $desc]): ?>
  <a class="carte" href="<?= htmlspecialchars($url, ENT_QUOTES) ?>">
    <strong><?= $titre ?></strong>
    <span><?= $desc ?></span>
  </a>
<?php endforeach; ?>
  <footer>Bluetooth : appareil « <?= htmlspecialchars(gethostname(), ENT_QUOTES) ?> » ·
    applications MPD : <?= $h ?>, port 6600</footer>
</main>
</body>
</html>
