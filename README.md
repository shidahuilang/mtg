# mtg
自用mtg-docker 


# 使用自定义端口
```
docker run -d \
  --name mtg \
  -p 9000:9000 \
  -e PORT=9000 \
  shidahuilang/mtg:latest
 ```
# 使用固定名称启动
```
docker run -d \
  --name mtg \
  -p 8443:8443 \
  -v ./data:/data \
  -e PORT=8443 \
  -e DOMAIN=hostupdate.vmware.com \
  shidahuilang/mtg:latest
```
查看日志打印链接
```
docker logs mtg
```
