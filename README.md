# AMINE · أمين

Approvisionnement des restaurants de Tunis. Application web en un seul fichier (`index.html`),
reliée à la base Supabase du projet « Amine ».

Le fichier ne contient que la clé publique (publishable) de Supabase, prévue pour être publiée :
tous les contrôles d'accès sont faits dans la base. Aucune clé secrète ne doit être ajoutée ici.

Fichiers de l'application installable (écran d'accueil, ouverture hors connexion) :
`manifest.webmanifest`, `sw.js` (service worker : ne met en cache que cette page et ses icônes,
jamais les données Supabase) et les icônes `*.png`.

Version 8 (schéma 5) : la base Supabase doit avoir reçu le script SQL de cette version (`amine.sql`,
à coller dans Supabase › SQL Editor ; il peut être rejoué sans risque) **avant** de publier cette page,
sinon l'application affiche « mise à jour de la base nécessaire ».

Le service worker affiche aussi les notifications push (application fermée) quand l'envoi est
activé dans l'administration et la fonction Supabase « amine-push » déployée.

Dossier `photos/` : images des articles du catalogue (JPEG 360 × 360 px), affichées à la place de
l'illustration dessinée pour les références qui en ont une (environ 160 sur 751). Ce sont des
**images générées par IA** fournies par l'exploitant, pas des photographies d'articles réels, et
elles ne portent ni licence ni crédit : les emballages de marque qu'elles montrent peuvent ne
pas correspondre exactement aux produits vendus. Un dépôt peut les remplacer article par article (fiche produit) ou en
masse avec « Photos réelles » (Wikimedia Commons, Open Food Facts, crédit enregistré). Si une
image ne charge pas, l'illustration reprend sa place.
