# Correcteur

Petite app pour la barre de menus du Mac. Elle repère quand tu écris, et dès que tu t'arrêtes de taper (0,5 s par défaut), elle relit ton texte et propose une correction : orthographe, grammaire, accords, apostrophes, homophones (a/à, sa/ça, ces/ses…).

Une bulle s'affiche avec les mots corrigés :
- en rouge barré, ce que tu avais écrit ;
- en vert, la correction.

| Touche | Effet |
|---|---|
| **⌥ Option + ⏎ Entrée** (ou bouton « Remplacer ») | applique la correction |
| **Échap**, ou continuer d'écrire | ignore la correction |

Ça marche dans Mail, Messages, Notes, Pages, WhatsApp, Slack, Gmail dans Safari ou Chrome, etc. L'app ne corrige jamais les champs mot de passe, les terminaux ni les éditeurs de code.

## Prérequis

- Un Mac avec une puce Apple (M1 ou plus récent), sous **macOS 26 (Tahoe)** ou plus récent.
- **Apple Intelligence activé** (Réglages Système → Apple Intelligence et Siri). La correction se fait alors **directement sur le Mac, gratuitement, sans rien envoyer sur Internet**.
- Optionnel : une clé API Claude pour des corrections plus fiables (voir plus bas).

## Installation

1. Dézippe `Correcteur.zip` et glisse **Correcteur.app** dans le dossier **Applications**.
2. Double-clique dessus. macOS va dire qu'il ne peut pas vérifier l'app, parce qu'elle n'est pas distribuée sur l'App Store. Va dans **Réglages Système → Confidentialité et sécurité**, descends tout en bas, puis clique sur **« Ouvrir quand même »**.
3. macOS demande l'autorisation **Accessibilité** : clique sur « Ouvrir les Réglages Système » et active **Correcteur**. C'est ce qui lui permet de lire et corriger le texte que tu tapes.
4. Une icône apparaît dans la barre de menus, en haut à droite. C'est prêt.

Dans le menu de l'icône, coche **« Lancer au démarrage du Mac »** pour ne plus avoir à y penser.

## Réglages (menu de l'icône)

Si l'icône est cachée (trop d'icônes ou encoche de l'écran), deux autres façons d'ouvrir le menu :
- le raccourci **⌃ Contrôle + ⌥ Option + ⌘ Commande + C**, n'importe où ;
- relancer l'app (Spotlight → « Correcteur », ou double-clic dans Applications) : le menu s'ouvre sous la souris.

- **Correction active** : met en pause ou réactive l'app.
- **Remplacer sans demander** : corrige directement, sans afficher la bulle.
- **Corriger après une pause de…** : le temps d'attente après la dernière touche.
- **Moteur de correction** :
  - **Apple Intelligence** : gratuit, rien ne quitte le Mac, réponse en moins d'une seconde, mais rate pas mal de fautes.
  - **Claude Code** : utilise ton abonnement Claude, si Claude Code est installé et connecté sur le Mac. Utilise Claude Haiku : bien plus fiable, réponse en moins d'une seconde (Claude Code est lancé à l'avance pendant que tu tapes).
  - **Claude API** : avec une clé créée sur console.anthropic.com. Bien plus fiable, environ un centime pour quelques dizaines de messages.
  - **Automatique** : prend la clé API si elle existe, sinon Claude Code, sinon Apple.

  Avec les deux moteurs Claude, les messages sont envoyés à Anthropic pour être corrigés.

  Dans le même menu, tu peux choisir le **modèle** séparément pour Claude Code (Haiku par défaut) et pour la clé API (Opus par défaut) : Haiku est le plus rapide et le moins cher, Opus le plus puissant, Sonnet entre les deux.

## Ce que veut dire l'icône

| Icône | État |
|---|---|
| ✏️ | tu es en train d'écrire |
| ⋯ | vérification en cours |
| ✓ | aucune faute trouvée |
| 💬 | une correction t'attend |
| ⚠️ | l'autorisation Accessibilité manque |

## Bon à savoir

- Dans les apps où **Entrée envoie le message** (WhatsApp, Slack…), attends une seconde avant d'envoyer pour laisser à la correction le temps d'arriver.
- Relis quand même la bulle avant de remplacer : le modèle intégré au Mac est bon, mais pas parfait.

## Recompiler (pour le développeur)

Il faut Xcode, puis :

```bash
./build.sh
```

Le fichier à partager se trouve ensuite dans `build/Correcteur.zip`.
