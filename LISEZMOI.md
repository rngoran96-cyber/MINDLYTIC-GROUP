# Gôly Express – version avec comptes et base de données

Contenu : `index.html` (page d’accueil publique + application), `schema.sql` (base de données, sécurité et abonnements).
Technologie : Supabase (comptes email + mot de passe, base PostgreSQL) et un hébergement de site statique gratuit.

## Installation (environ 15 minutes)

1. **Créer le projet Supabase** : supabase.com → New project (choisissez la région la plus proche).
2. **Créer les tables** : menu *SQL Editor* → New query → collez tout `schema.sql` → *Run*.
3. **Désactiver la confirmation d’email** : *Authentication* → *Sign In / Providers* → *Email* → décochez « Confirm email ».
   Sans cela, la création d’un livreur par le gestionnaire ne peut pas aboutir.
4. **Récupérer les clés** : *Project Settings* → *API*. Copiez « Project URL » et la clé « anon / public ».
5. **Configurer l’application** : ouvrez `index.html` dans un éditeur de texte. En haut du script, remplacez
   `SUPABASE_URL` et `SUPABASE_KEY` par vos valeurs. N’utilisez jamais la clé `service_role`.
6. **Mettre en ligne** : déposez le dossier sur Netlify Drop (app.netlify.com/drop), Vercel ou GitHub Pages.
7. **Créer votre compte gestionnaire (droit de valider les paiements)** : ouvrez `creer-compte-gestionnaire.sql`, modifiez les 5 valeurs
   en haut (email, mot de passe, prénom, nom, téléphone), collez le tout dans *SQL Editor* → *Run*.
   Ce compte a un abonnement gratuit jusqu'en 2099 et voit le menu « Paiements à valider ». Changez ensuite le mot de passe dans « Mon profil ».
   (Si le script échoue à la création de l'utilisateur, créez le compte avec « Créer un compte » dans l'application, puis relancez le script.)
8. **Paiement automatique Wave** : voir la section « Wave Business » plus bas.
9. **Premier test** : ouvrez le site → « Créer un compte » (gestionnaire) → « Mes livreurs » → créez un livreur
   → créez une commande et attribuez-la → connectez-vous avec le livreur (autre navigateur) pour vérifier.

## Abonnement des gestionnaires

- **Activation (première utilisation) : 120 000 FCFA**, paiement unique. **Ensuite 40 000 FCFA par mois.**
- Hypothèse retenue : l’activation inclut les 30 premiers jours, puis chaque paiement mensuel ajoute 30 jours.
  Si vous voulez autre chose (par exemple activation + 1er mois séparés), dites-le-moi.
- Le gestionnaire paie avec Wave depuis « Abonnement » : l’accès s’ouvre ou se prolonge automatiquement.
- Sans abonnement actif, le gestionnaire ne peut plus créer ni modifier de commandes ni créer de livreurs.
  Ce blocage est appliqué par la base de données. Les données restent conservées.
- Pour changer les prix : modifiez `PRIX_ACTIVATION` / `PRIX_MENSUEL` dans `index.html` **et** la fonction `price_of` dans `schema.sql`.
  Si vous modifiez seulement l’un des deux, les paiements seront refusés.
- Le paiement Wave n’est pas un prélèvement automatique : chaque mois, le gestionnaire doit cliquer sur « Payer avec Wave ».
- La validation manuelle (« Paiements à valider ») reste disponible en secours.

## Wave Business (paiement automatique)

Le gestionnaire clique sur « Payer avec Wave », règle dans l’application Wave, et son accès s’ouvre automatiquement
(sans que vous validiez à la main). Le prix est décidé côté serveur (fonction `price_of` du SQL), jamais par le navigateur.

1. **Clé API Wave** : portail Wave Business → Développeur → clés API. Créez une clé avec l’accès « Checkout API ».
   Vous pouvez activer la signature des requêtes : vous recevez alors un « signing secret » (`wave_sn_AKS_…`).
   N’activez **pas** la liste d’adresses IP autorisées : les fonctions Supabase n’ont pas d’adresse fixe.
   Si Wave répond `unauthorized-wallet`, contactez votre interlocuteur Wave pour faire activer l’API Checkout sur votre compte.
2. **Installer l’outil Supabase** (une fois) : `npm i -g supabase`, puis `supabase login` et `supabase link --project-ref VOTRE_REF`
   (la référence est dans l’URL de votre projet).
3. **Enregistrer les secrets** (remplacez les valeurs ; SITE_URL = l’adresse https de votre site, sans `/` final) :
   `supabase secrets set WAVE_API_KEY=wave_sn_prod_... SITE_URL=https://votre-site.netlify.app`
   et, si vous avez activé la signature de requêtes : `supabase secrets set WAVE_SIGNING_SECRET=wave_sn_AKS_...`
4. **Déployer les deux fonctions** depuis le dossier du projet :
   `supabase functions deploy wave-checkout` puis `supabase functions deploy wave-webhook --no-verify-jwt`
5. **Déclarer le webhook dans Wave** : portail Wave → Développeur → Webhooks → ajouter.
   URL : `https://VOTRE_REF.supabase.co/functions/v1/wave-webhook` · Stratégie : **Signing Secret** · Événement : `checkout.session.completed`.
   Wave affiche le secret du webhook **une seule fois** : copiez-le, puis `supabase secrets set WAVE_WEBHOOK_SECRET=wave_sn_WHS_...`
6. **Tester avec un petit montant** : dans `schema.sql`, la fonction `price_of` fixe les prix. Pour le test, exécutez dans *SQL Editor*
   `create or replace function public.price_of(k text) returns integer language sql immutable as $$ select 100 $$;`
   (et mettez temporairement `PRIX_ACTIVATION=100,PRIX_MENSUEL=100` dans `index.html`), faites un paiement avec un compte gestionnaire de test,
   vérifiez que l’accès s’ouvre, puis **remettez les vrais prix** (120000 / 40000) aux deux endroits.
7. En cas de souci (client qui a payé mais accès non ouvert) : consultez les journaux dans Supabase → Edge Functions → wave-webhook,
   ou utilisez « Payer autrement » (déclaration manuelle) puis validez dans « Paiements à valider ».

Sécurité : la signature de chaque webhook est vérifiée (HMAC-SHA256 sur horodatage + corps brut, 5 minutes maximum d’écart),
le montant est contrôlé, et un même paiement ne peut pas être appliqué deux fois. Wave prélève ses frais sur votre compte marchand.

## Fonctionnement

- **Gestionnaire** : crée son compte lui-même. Il ne voit que ses commandes et ses livreurs.
- **Livreur** : créé par le gestionnaire (email + mot de passe). Il voit uniquement les commandes qui lui sont attribuées
  et ne peut modifier que leur statut. Cette règle est appliquée par la base (pas seulement par l’écran).
- Les changements apparaissent en direct chez tout le monde.
- « Retirer » un livreur supprime son accès à l’application. Son compte de connexion reste dans Supabase
  (supprimable dans *Authentication* → *Users*).

## Limites à connaître

- Ce code n’a pas pu être testé contre un vrai projet Supabase depuis mon environnement : faites le test de l’étape 9
  avant de l’utiliser avec de vrais clients.
- Pas de « mot de passe oublié ».
- Les « paiements électroniques » des commandes clients sont seulement enregistrés, pas encaissés par l’application.
- Pour un usage réel, prévoyez l’envoi d’emails par votre propre service (Supabase limite les emails du plan gratuit)
  si vous réactivez la confirmation d’email plus tard.
