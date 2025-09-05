# Git Commands

## 기본 작업

* 저장소 초기화
```
git init
```

* 원격 저장소 복제
```
git clone <url>
```

* 현재 상태 확인
```
git status
```

* 변경 내용 확인
```
git diff
```

## Staging & Commit

* 파일 추가(스테이징)
```
git add <파일명>
git add .   # 전체 파일
```

* 커밋 만들기
```
git commit -m "메시지"
```

* 스테이징과 동시에 커밋
```
git commit -am "메시지"
```

## remote (fetch/pull/push)

* 원격 저장소 확인
```
git remote -v
```

* 원격 주소 변경
```
git remote set-url origin <url>
```

* 원격 저장소 동기화
```
git fetch
```

* 원격 변경 가져오기
```
git pull origin <브랜치명>
```

* 원격에 푸시
```
git push origin <브랜치명>
```

## Branch

* 브랜치 목록
```
git branch
```

* 브랜치 생성
```
git branch <브랜치명>
```

* 브랜치 이동
```
git checkout <브랜치명>
git switch <브랜치명>   # 최신 방식
```

* 브랜치 생성 + 이동
```
git checkout -b <브랜치명>
git switch -c <브랜치명>
```

* 브랜치 삭제
```
git branch -d <브랜치명>
```