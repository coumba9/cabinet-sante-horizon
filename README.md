# Cabinet Santé Horizon

Application de prise de rendez-vous d’un cabinet médical unique. Le parcours s’arrête à l’arrivée du patient devant le médecin.

## Démarrage local

```powershell
npm install
npm run dev
```

Sans paramètres Supabase, l’application propose le mode démonstration interactif Patient / Médecin / Admin. Ses données sont locales et temporaires.

## Activer Supabase

1. Créer un projet Supabase.
2. Exécuter dans l’ordre toutes les migrations `supabase/migrations/202611090001_schema.sql` à `supabase/migrations/202611120001_sms_delivery_and_phone_verification.sql`, y compris les migrations intermédiaires `202611110001` à `202611110003`.
3. Copier `.env.example` vers `.env.local`, puis définir `VITE_SUPABASE_URL` et `VITE_SUPABASE_ANON_KEY`.
4. Lier le projet avec `supabase link --project-ref <project-ref>`.
5. Déployer les fonctions :

```powershell
supabase functions deploy create-account
supabase functions deploy manage-doctor
supabase functions deploy identifier-login
supabase functions deploy verify-phone
supabase functions deploy seed-demo
supabase functions deploy send-appointment-sms-reminders
```

Configurer `DEXNOTIFY_API_KEY` et, si nécessaire, `DEXNOTIFY_SMS_SENDER` dans les secrets Supabase. La fonction de vérification envoie un code à usage unique; l’inscription patient et l’activation des rappels exigent un numéro vérifié. Le consentement SMS est demandé lors de l’inscription et à chaque réservation. Les rappels sont enregistrés par rendez-vous, recalculés après report et annulés à l’annulation. Les heures sont calculées en UTC, identique à l’heure de Dakar. Les SMS ne contiennent que la date, l’heure, la spécialité et les indications d’annulation.

Si la fonction `paytech-payment` avait déjà été déployée auparavant, redéployez-la une fois pour désactiver l’ancien parcours de paiement.

La configuration de `verify_jwt` se trouve dans `supabase/config.toml`. Les fonctions avec une inscription publique ou un webhook vérifient elles-mêmes leur identité ou leur signature.

## Comptes de démonstration Supabase

Les trois spécialités sont créées par la première migration. Pour disposer des comptes, médecins, disponibilités et rendez-vous d’exemple, définir les secrets serveur puis appeler une fois la fonction `seed-demo` :

```powershell
supabase secrets set DEMO_SEED_SECRET="un-secret-long-et-unique" DEMO_PASSWORD="un-mot-de-passe-de-demo-long"
```

Appeler `POST https://<project-ref>.supabase.co/functions/v1/seed-demo` avec l’en-tête `x-demo-seed-secret` contenant la valeur de `DEMO_SEED_SECRET`. La réponse liste les identifiants; chaque compte de démonstration utilise le mot de passe `DEMO_PASSWORD`. Identifiants créés : `admin.demo`, `awa.demo`, `ibrahima.demo`, `mamadou.demo`, `fatou.med.demo`, `aminata.demo`, `moussa.demo`, `fatou.patient.demo`, `ibrahima.patient.demo`, `mariama.demo`.

Le seeding est répétable : il réutilise les comptes et ajoute uniquement les plages et rendez-vous d’exemple manquants. Réservez ces comptes à un projet de démonstration, et changez le mot de passe avant toute présentation externe.

## Parcours reliés à la base

- Inscription patient par `create-account`; identifiant converti côté serveur en adresse technique `identifiant@cabinet.local`.
- Vérification du numéro mobile sénégalais par code SMS avant la création du compte et l’activation des rappels.
- Notifications SMS de confirmation, de reprogrammation, 24 h et 5 h avant; les rappels déjà échus sont omis et ceux d’un rendez-vous annulé sont invalidés.
- Connexion, restauration de session, déconnexion et vérification des comptes bloqués.
- Réservation avec liste de créneaux réellement ouverts. Le contrôle atomique de capacité est exécuté par PostgreSQL; le refus « créneau complet » est renvoyé au patient.
- Consultation des rendez-vous et des informations utiles de patient par le médecin autorisé.
- Confirmation de rendez-vous et message de confirmation stocké en base.
- Gestion des disponibilités, blocage/libération des créneaux, annulation et reprogrammation patient. Le délai de modification est réglable par l’administrateur dans Rapports (24 h par défaut).
- Gestion des spécialités et des comptes médecins par l’administration, avec refus de suppression lorsqu’un paiement historique dépend du médecin.
- États récapitulatifs sans noms ni données de soins pour l’administrateur.
- Messages limités aux participants d’un rendez-vous et actualisés en temps réel.
- Le médecin peut terminer une consultation à partir de l’heure prévue. L’enregistrement d’un paiement ne modifie jamais le statut du rendez-vous.

Le paiement a été retiré de l’espace médecin et n’est pas encore proposé dans l’application. Son emplacement sera défini ultérieurement.

## Sécurité

- Les rôles sont stockés séparément dans `user_roles`; les tables métier ont RLS.
- L’administrateur n’a pas de lecture directe des rendez-vous ou paiements; les rapports passent par une fonction qui ne renvoie que des agrégats.
- Les opérations de rendez-vous et de message passent par des RPC qui valident rôle, propriétaire, spécialité, plage et statut.
- Les comptes médecin sont créés et administrés par des Edge Functions vérifiant le rôle administrateur.
- Le secret `service_role` et le secret de seed ne doivent jamais être exposés au navigateur.
