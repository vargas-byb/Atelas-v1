# Como atualizar o Atelas Client

1. Edite `index.html` (o app inteiro está nele). Para mudar o formato dos dados, aumente `DATA_VERSION` e acrescente um passo em `migrate()`. Nunca troque `KEY` (`meudia.v1`).
2. Aumente `APP_VERSION` no `index.html` e `versionCode`/`versionName` dentro do `build.sh` (o Android só instala por cima se o número for maior).
3. Envie para o GitHub. O APK é gerado em Actions > Gerar APK do Atelas Client > Artifacts.
4. Instale o APK por cima do antigo. Os dados continuam.

Guarde `atelas-release.jks` e `keystore.properties`. Sem eles não dá para atualizar o app instalado. Mantenha o repositório privado.

## Widget da tela inicial (a partir da 1.4.0)
O `build.sh` cria o widget nativo (`AtelasWidgetProvider`, `AtelasWidgetPlugin` e os XMLs). Depois de instalar o APK, abra o app uma vez, segure um espaço vazio da tela inicial do celular, toque em Widgets e escolha "Atelas Client". Ele mostra os avisos e as contas do dia e abre o app ao toque.
