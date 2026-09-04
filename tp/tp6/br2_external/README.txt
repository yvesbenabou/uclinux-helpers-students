BR2_EXTERNAL du TP6 : my_hello et fb-test-app-minimal

Arborescence :
  external.desc
  Config.in
  external.mk
  package/my_hello/Config.in
  package/my_hello/my_hello.mk
  package/my_hello/src/my_hello.c
  package/fb-test-app-minimal/Config.in
  package/fb-test-app-minimal/fb-test-app-minimal.mk

Exemple d'utilisation depuis l'arbre Buildroot :

  make BR2_EXTERNAL="$HOME/uclinux-helpers/tp/tp6/br2_external" \
       O="$HOME/uclinux/outputs/qemu" menuconfig

Puis, dans External options, activer my_hello et/ou fb-test-app-minimal, puis reconstruire :

  make O="$HOME/uclinux/outputs/qemu"

L'exécutable est installé dans :
  /usr/bin/my_hello
  /usr/bin/fb-test et /usr/bin/fb-test-perf (avec fb-test-app-minimal)

On DOIT mettre à jour avec make fb-test-app-rebuild fb-test-app-minimal-reinstall all:
  - fb-test-app-rebuild reconstruit dans build/fb-test-app-1.1.1
  - fb-test-app-minimal-reinstall: execute la regle install de fb-test-app-minimal: ne garde que fb-test et fb-test-perf
  - all: refait le rootfs.romfs

Remarque : après le premier appel avec BR2_EXTERNAL, Buildroot mémorise
le chemin dans le répertoire de sortie ; il n'est normalement plus nécessaire
de repasser BR2_EXTERNAL à chaque commande make pour ce même O=.
fb-test-app-minimal sélectionne le paquet Buildroot fb-test-app, puis ne garde que :
  /usr/bin/fb-test
  /usr/bin/fb-test-perf

Les variantes rect, offset et string sont supprimées du rootfs final.
Le paquet amont compile toujours les cinq programmes.
