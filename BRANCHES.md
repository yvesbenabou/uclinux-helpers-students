# Guide des branches

La branche par défaut est `initramfs`. Les noms décrivent les variantes du
cours, sans préfixe `stm32_` : chacune propose une cible STM32F429 Discovery
et une cible QEMU ARM VExpress. QEMU n'émule pas la carte STM32.

Toutes utilisent Buildroot 2025.08.

| Branche étudiante | STM32 | QEMU |
| --- | --- | --- |
| `initramfs` | AFBOOT, initramfs intégré au noyau | Linux direct, initramfs intégré |
| `initramfs_fb` | Idem, avec framebuffer LCD | Linux direct, initramfs intégré |
| `initramfs_uboot` | U-Boot, initramfs intégré | U-Boot → Linux, initramfs intégré |
| `romfs` | AFBOOT, ROMFS séparé | Linux direct, disque ext2 |
| `romfs_fb` | Idem, avec framebuffer LCD | Linux direct, disque ext2 |
| `romfs_uboot` | U-Boot, ROMFS séparé | U-Boot → Linux, disque ext2 |

`fb` concerne l'écran STM32 ; aucun framebuffer équivalent n'est ajouté sous
QEMU. De même, les branches `romfs` conservent ext2 sous QEMU.

## Choisir et utiliser une branche

```sh
git clone https://github.com/yvesbenabou/uclinux-helpers-students.git
cd uclinux-helpers-students
git switch romfs_fb
```

Depuis la racine du dépôt, après les étapes d'installation 1 et 2 :

```sh
# Construire puis lancer QEMU
./3_uclinux_qemu_dl_and_build.sh --quiet
./run_qemu_image.sh

# Ou construire puis flasher la STM32 connectée
./4_uclinux_stm32_dl_and_build.sh --quiet
./run_openocd_stm32.sh flash --verify
```

Le flash écrit réellement la mémoire de la carte. Un changement de branche
réinitialise les sorties au prochain build ; les ajouts manuels dans `target/`
sont perdus. Conserver et versionner les sources hors des sorties de build.
Pendant le cours drivers, conserver la branche choisie et versionner les
drivers dans le dépôt séparé `linux-drivers-labs`.

Les six branches fournissent `tp/tp3/br2_external`. `romfs_fb` fournit aussi
`tp/tp6/br2_external`. Exemple de sélection explicite :

```sh
./3_uclinux_qemu_dl_and_build.sh --br2-external "$PWD/tp/tp3/br2_external"
```

## Mettre à jour un clone existant après le renommage

Chaque ancien nom perd uniquement son préfixe `stm32_`. Exemple pour une
branche locale existante, sans branche locale `initramfs` déjà créée :

```sh
git fetch origin --prune
git branch -m stm32_initramfs initramfs
git branch --set-upstream-to=origin/initramfs initramfs
git remote set-head origin -a
```

Adapter les deux noms à la branche concernée et `origin` au nom du remote.
Les noms de répertoires tels que `stm32_romfs/`, les fonctions et les scripts
spécifiques à la carte ne sont pas renommés : ils décrivent toujours la STM32.
