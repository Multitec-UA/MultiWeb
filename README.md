# Web de MultitecUA

Proyecto colaborativo para el desarollo de una web informativa por los miembros de la asociación MultitecUA de la Universidad de Alicante.

## Version
##########
release-v1
##########



## Build docker
```
docker build -t multiweb .
```

## Run docker
```
docker run -d -p 80:80 -t multiweb
```

## Deploy
Caundo se hace push con un cambio a la rama principal, se despliega en GCloud
