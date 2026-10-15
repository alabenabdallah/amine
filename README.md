# AMINE · أمين

Approvisionnement des restaurants de Tunis. Application web en un seul fichier (`index.html`),
reliée à la base Supabase du projet « Amine ».

Le fichier ne contient que la clé publique (publishable) de Supabase, prévue pour être publiée :
tous les contrôles d'accès sont faits dans la base. Aucune clé secrète ne doit être ajoutée ici.

Fichiers de l'application installable (écran d'accueil, ouverture hors connexion) :
`manifest.webmanifest`, `sw.js` (service worker : ne met en cache que cette page et ses icônes,
jamais les données Supabase) et les icônes `*.png`.

Version 4 : la base Supabase doit être en version 4 (script SQL de la version 4 exécuté dans
Supabase › SQL Editor) avant de publier cette page, sinon l'application affiche « mise à jour
de la base nécessaire ».

Le service worker affiche aussi les notifications push (application fermée) quand l'envoi est
activé dans l'administration et la fonction Supabase « amine-push » déployée.
