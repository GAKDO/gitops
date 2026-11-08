# 탐지 모델 폴더 (inspect-worker)

이 폴더가 inspect-worker 컨테이너의 `/models`로 붙습니다(읽기 전용). 폰 사진 흠집 탐지에 쓰는 모델을 여기 둡니다.

| 파일 | 내용 |
| --- | --- |
| `best.onnx` | 집 PC 학습 결과의 ONNX(`trace-ml train`이 만든 것, 부스 Jetson 엔진을 만든 것과 같은 파일) |
| `model.json` | 같은 폴더의 모델 정보(`modelVersion`·`classes`). 클래스가 codes.yaml과 다르면 워커가 시작하지 않습니다 |

## 모델 바꾸기

```bash
cd ~/gitops/compose
cp /경로/best.onnx /경로/model.json models/
docker compose restart inspect-worker
docker compose logs --tail 20 inspect-worker   # "폰 탐지 모델 <modelVersion>"이 보이면 끝
```

부스(Jetson)도 같은 `best.onnx`로 `trace-booth build-engine`을 다시 하면 두 곳의 모델이 같아집니다. 성능 화면의 mAP는 `.env`의 `MODEL_METRICS`(capture-server)에 새 `modelVersion`으로 더한 뒤 `docker compose up -d capture-server`로 다시 만듭니다(restart만으로는 바뀐 `.env`를 읽지 않습니다).

폴더가 비어 있으면 워커는 탐지만 건너뛰고 정합·3D 텍스처는 계속합니다(결과의 modelVersion이 `contour-v1`).

모델 파일은 git에 올리지 않습니다(`.gitignore`).
