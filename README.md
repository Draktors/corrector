# Correcteur

Petite app pour la barre de menus du Mac, pensée pour toute personne qui fait des fautes en tapant vite.

Elle repère quand tu écris. Dès que tu t'arrêtes de taper (0,5 s par défaut), elle relit ton texte et propose une correction : orthographe, fautes de frappe, grammaire, conjugaison, accords, apostrophes oubliées (jai → j'ai), homophones (a/à, sa/ça, ces/ses, on/ont…).

Elle **ne reformule pas** : ton style, ton ton et tes mots restent les tiens, seules les fautes sont corrigées.

Une bulle s'affiche sous ton texte avec les corrections :
- en rouge barré, ce que tu avais écrit ;
- en vert, la correction.

Ça marche dans Mail, Messages, Notes, Pages, WhatsApp, Slack, Claude, Gmail dans Safari ou Chrome, etc.

## Raccourcis

| Touche | Effet |
|---|---|
| **⌘ Commande + ⏎ Entrée** (ou bouton « Remplacer ») | applique la correction |
| **Échap**, ou continuer d'écrire | ignore la correction |
| **⌃ Contrôle + ⌥ Option + ⌘ Commande + C** | ouvre le menu de l'app, n'importe où |

⌘ + Entrée et Échap ne sont captés **que pendant que la bulle est affichée**. Le reste du temps, ils gardent leur rôle habituel dans tes apps.

## Prérequis

- Un Mac avec une puce Apple (M1 ou plus récent), sous **macOS 26 (Tahoe)** ou plus récent.
- Au moins un des trois moteurs de correction :

| Moteur | Ce qu'il faut | Qualité | Vitesse | Coût | Confidentialité |
|---|---|---|---|---|---|
| **Claude Code** | Claude Code installé et connecté à ton abonnement Claude | très bonne | moins d'1 s | inclus dans l'abonnement | texte envoyé à Anthropic |
| **Claude API** | une clé API (console.anthropic.com) | très bonne | environ 1 s | quelques centimes par mois | texte envoyé à Anthropic |
| **Apple Intelligence** | Apple Intelligence activé (Réglages Système → Apple Intelligence et Siri) | moyenne : rate pas mal de fautes | moins d'1 s | gratuit | rien ne quitte le Mac |

En mode **Automatique** (par défaut), l'app prend la clé API si tu en as ajouté une, sinon Claude Code s'il est installé, sinon Apple Intelligence. Si un moteur Claude échoue, elle se rabat sur Apple Intelligence, puis sur le correcteur orthographique de macOS.

## Installation

1. Dézippe `Correcteur.zip` et glisse **Correcteur.app** dans le dossier **Applications**.
2. Double-clique dessus. macOS va dire qu'il ne peut pas vérifier l'app, parce qu'elle n'est pas distribuée sur l'App Store. Va dans **Réglages Système → Confidentialité et sécurité**, descends tout en bas, puis clique sur **« Ouvrir quand même »**.
3. macOS demande l'autorisation **Accessibilité** : clique sur « Ouvrir les Réglages Système » et active **Correcteur**. C'est ce qui permet à l'app de lire et de corriger le texte que tu tapes. Elle se relance toute seule une fois l'autorisation donnée.
4. Une icône apparaît dans la barre de menus. C'est prêt.

Dans le menu, coche **« Lancer au démarrage du Mac »** pour ne plus avoir à y penser.

## Le menu

Clique sur l'icône dans la barre de menus. Si elle est cachée (trop d'icônes ou encoche de l'écran), deux autres façons d'ouvrir le menu :
- **⌃⌥⌘C**, n'importe où ;
- relancer l'app (Spotlight → « Correcteur », ou double-clic dans Applications). Le menu s'ouvre alors sous la souris.

Pour faire réapparaître l'icône, maintiens **⌘** et fais-la glisser vers la droite de la barre de menus.

**Réglages disponibles :**

- **Correction active** : met l'app en pause ou la réactive.
- **Remplacer sans demander** : corrige directement, sans afficher la bulle.
- **Corriger après une pause de…** : le temps d'attente après la dernière touche (de 500 ms à 4 s).
- **Moteur de correction** :
  - le moteur : Automatique, Apple Intelligence, Claude Code ou Claude API ;
  - le **modèle**, séparément pour Claude Code (Haiku par défaut) et pour la clé API (Opus par défaut). Haiku est le plus rapide et le moins cher, Opus le plus puissant, Sonnet entre les deux ;
  - **Ajouter / modifier la clé API Claude** : la clé est rangée dans le Trousseau macOS. Pour la supprimer, vide le champ et enregistre.
- **Lancer au démarrage du Mac**.

## Ce que veut dire l'icône

| Icône | État |
|---|---|
| ✏️ | tu es en train d'écrire |
| ⋯ | vérification en cours |
| ✓ | aucune faute trouvée |
| 💬 | une correction t'attend |
| ⏸ | correction en pause |
| ⚠️ | l'autorisation Accessibilité manque |

## Ce que l'app ne fait jamais

- Lire les **champs mot de passe** ou les barres de recherche.
- Corriger dans les **terminaux, éditeurs de code et gestionnaires de mots de passe** (Terminal, iTerm, Warp, Ghostty, Xcode, VS Code, Cursor, 1Password, Bitwarden…).
- Corriger un texte d'un seul mot (URL, identifiant…) ou de plus de 4 000 caractères.
- Garder une trace de ce que tu écris : le journal de diagnostic ne contient que les étapes, jamais le texte.

Avec les moteurs Claude, le texte à corriger est envoyé à Anthropic. Claude Code est lancé sans outils, sans historique et sans accès à tes fichiers : il ne fait que corriger.

## Bon à savoir

- Dans les apps où **Entrée envoie le message** (WhatsApp, Slack…), laisse une seconde à la bulle avant d'envoyer.
- Relis quand même la bulle avant de remplacer, surtout avec Apple Intelligence.
- Dans les pages web et les apps comme Slack, le remplacement passe par un copier-coller. Ton presse-papiers est restauré juste après.

## Dépannage

**Rien ne se passe quand je tape.**
L'autorisation Accessibilité n'est sans doute pas active pour cette version de l'app. Dans Réglages Système → Confidentialité et sécurité → Accessibilité, supprime Correcteur (bouton −), relance l'app et accepte à nouveau. Si ça ne suffit pas, lance cette commande dans le Terminal, puis relance l'app :

```bash
tccutil reset Accessibility com.local.correcteur
```

**Je veux savoir ce qui se passe.**
Le journal de diagnostic est dans `~/Library/Logs/Correcteur.log`. Il note chaque étape (frappe détectée, champ lu, moteur utilisé, temps de réponse, bulle affichée, remplacement), jamais le texte.

## Pour le développeur

Il faut Xcode (ou ses outils en ligne de commande), puis :

```bash
./build.sh
```

Ça compile `build/Correcteur.app` et crée `build/Correcteur.zip`, le fichier à partager. La signature est fixée sur l'identifiant de l'app (`com.local.correcteur`) : l'autorisation Accessibilité est conservée d'une compilation à l'autre.

| Fichier | Rôle |
|---|---|
| `Sources/TypingWatcher.swift` | détecte le début de la frappe et la pause |
| `Sources/AXText.swift` | lit et remplace le texte du champ actif (Accessibilité, copier-coller pour le web) |
| `Sources/Corrector.swift` | choix du moteur, consignes de correction, garde-fous contre les réécritures |
| `Sources/ClaudeCodeClient.swift` | moteur Claude Code (`claude -p`, lancé à l'avance pendant la frappe) |
| `Sources/ClaudeClient.swift` | moteur Claude API et stockage de la clé dans le Trousseau |
| `Sources/SuggestionPanel.swift` | bulle de correction et raccourcis |
| `Sources/AppDelegate.swift` | barre de menus, réglages, enchaînement des étapes |
| `Sources/WordDiff.swift` | différence mot à mot affichée dans la bulle |
