# 공지소통게시판 — MVP v0.2

기존 질문·답변 게시판에 **검색엔진 비노출 요청**과 **사이트 공통 입장 비밀번호**를 추가한 버전입니다. 로그인/회원가입 없이 이용합니다.

## 파일 5개
- `index.html`: 질문 검색·등록·답변·수정·삭제·아코디언·조회수·상단 고정 및 입장 화면
- `setup.sql`: Supabase DB·RPC·공통 입장 암호·임시 입장 토큰 검증
- `robots.txt`: 크롤러 수집 제한 요청
- `_headers`: Netlify에서 `X-Robots-Tag` 헤더 설정
- `README.md`: 실행 방법

## 설정 (새 프로젝트 또는 기존 v0.1 업데이트)

1. Supabase 프로젝트를 개설하고 SQL Editor를 엽니다.
2. `setup.sql`에서 아래 두 문자열을 **각기 다른 강력한 비밀번호**로 교체합니다.
   - `CHANGE_THIS_ADMIN_PASSWORD`: 관리자 암호
   - `CHANGE_THIS_ENTRY_PASSWORD`: 게시판 공통 입장 암호
3. SQL Editor에서 **전체** `setup.sql`을 한 번 실행합니다. 기존 v0.1 프로젝트에서도 기존 글을 보존하면서 이전의 무인증 RPC 함수를 제거하도록 구성했습니다. 기존 환경에서는 먼저 DB 백업을 권장합니다. 기존 프로젝트에 다른 사용자 정의 public SQL 함수가 있다면 마지막 `revoke execute on all functions in schema public` 구문은 다른 함수의 사용에도 영향을 줄 수 있으므로 별도 프로젝트를 권장합니다.
4. Supabase의 **Project URL**과 **Publishable key** (구형 프로젝트라면 anon key)를 확인해 `index.html`의 `SUPABASE_URL`과 `SUPABASE_KEY`에 입력합니다. **service_role/secret key는 절대 입력하지 마세요.**
5. Netlify에 5개 파일을 같은 게시 디렉터리로 배포합니다. `index.html`만 올리면 `robots.txt`/`_headers` 설정은 적용되지 않습니다.
6. 접속 후 공통 입장 암호를 입력하여 글을 열람하고, 게시글 수정/삭제는 작성 암호 또는 관리자 암호로 진행합니다.

## 접근 제한 구조

- 게시판 화면은 입장 전 표시하지 않습니다. `index.html` HTML/CSS/JS 자체는 공개 정적 파일입니다.
- **데이터는 서버에서 보호합니다.** Supabase RPC의 질문 목록·검색·상세 조회·등록·수정·삭제·상단 고정·관리자 인증은 모두 서버에서 **입장 토큰**을 검사합니다.
- 입장 암호는 DB에 bcrypt 해시로 저장, 성공 시 12시간짜리 일시 토큰 발급. DB에는 토큰 해시만 저장합니다. 토큰은 브라우저 메모리에만 보관하므로 새로고침 시 입장 암호를 다시 입력해야 합니다. '퇴장' 버튼은 서버 토큰을 폐기합니다.
- 게시글별 작성 암호와 관리자 암호도 서버에서 확인합니다. RLS 및 테이블 접근 권한을 제한합니다.
- 입장 암호를 아는 이용자는 게시판 내 모든 질문/답변을 열람할 수 있습니다. 작성 비밀번호는 글 수정/삭제에만 사용합니다.

## 검색 노출 방지의 한계

- `meta robots=noindex`와 Netlify `X-Robots-Tag` 헤더로 검색 결과 등록을 막도록 요청하고 `robots.txt`로 수집 제한을 요청합니다.
- **robots.txt에 의해 크롤링이 차단된 페이지는 로봇이 noindex를 확인하지 못할 수 있습니다.** 두 규칙을 함께 사용해도 URL 자체의 검색 결과 노출을 100% 보장하지 않습니다. 실제 게시글 내용 보호는 Supabase의 서버 측 입장 인증으로 수행합니다.
- 일반적인 정적 호스팅이므로 HTML 파일과 URL 자체는 공개될 수 있습니다. 사이트의 정적 파일까지 완전히 숨기려면 호스팅 단계에서 별도 접근 제어가 필요합니다.
- 공통 비밀번호는 전달받은 사람 누구나 사용할 수 있고, 계정별 통제·누가 접속했는지 추적할 수 없습니다. 암호 무차별 대입 방어·속도 제한·CAPTCHA는 이 MVP 범위에 없습니다. 다수가 이용하는 공개 운영 전에는 Netlify 접근 제한 또는 서버 측 rate-limit 추가가 필요합니다.

## 점검 체크리스트

1. 입장 전 질문 목록이 보이지 않는지 확인
2. 올바르지 않은 암호로 입장이 거부되는지 확인
3. 올바른 암호로 입장하여 질문 검색 및 답변 열람 확인
4. 브라우저 개발자 도구에서 입장 토큰 없이 `/rest/v1/rpc/board_list` 요청 시 거부되는지 확인
5. 게시글 작성·수정·삭제의 작성 비밀번호 및 관리자 비밀번호 검증
6. 답변 `(n)` 집계, 상단 고정, 조회수 증가 확인
7. 퇴장 후 기존 토큰으로 요청 시 거부되는지 확인
8. Netlify 배포 후 `/robots.txt` 응답과 HTML의 `noindex`, HTTP `X-Robots-Tag` 헤더 확인

## 참조
- Supabase Database Functions: https://supabase.com/docs/guides/database/functions
- Google Search Central noindex: https://developers.google.com/search/docs/crawling-indexing/block-indexing
