# 개발 가이드

StableNet PoC 컨트랙트 개발을 위한 가이드입니다.

## 개발 환경 설정

### 1. Foundry 설치

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 2. 프로젝트 클론 및 의존성 설치

```bash
git clone <repository-url>
cd poc-contract
git submodule update --init --recursive
```

### 3. 환경 변수 설정

```bash
cp .env.example .env
# .env 파일 편집
```

### 4. 빌드 확인

```bash
forge build
```

## 프로젝트 구조

```
poc-contract/
├── src/                    # 소스 코드
│   ├── erc4337-*/          # ERC-4337 관련
│   ├── erc7579-*/          # ERC-7579 관련
│   ├── privacy/            # 프라이버시
│   ├── compliance/         # 규제 준수
│   ├── tokens/             # 토큰
│   └── defi/               # DeFi
├── test/                   # 테스트
├── script/                 # 배포 스크립트
│   ├── deploy/             # 카테고리별 배포
│   └── utils/              # 유틸리티
├── lib/                    # 외부 의존성
├── docs/                   # 문서
├── deployments/            # 배포 결과
└── foundry.toml            # Foundry 설정
```

## 코딩 컨벤션

### 네이밍

```solidity
// 컨트랙트: PascalCase
contract MyContract {}

// 함수: camelCase
function myFunction() public {}

// 상수: UPPER_SNAKE_CASE
uint256 public constant MAX_VALUE = 100;

// 내부 함수: _camelCase
function _internalFunction() internal {}

// 이벤트: PascalCase
event MyEvent(address indexed user);

// 에러: PascalCase
error MyError();
```

### 파일 구조

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// 1. Imports
import {Contract} from "./Contract.sol";

// 2. Interfaces
interface IMyContract {}

// 3. Libraries
library MyLibrary {}

// 4. Contracts
contract MyContract {
    // 4.1 Type declarations
    // 4.2 State variables
    // 4.3 Events
    // 4.4 Errors
    // 4.5 Modifiers
    // 4.6 Constructor
    // 4.7 External functions
    // 4.8 Public functions
    // 4.9 Internal functions
    // 4.10 Private functions
}
```

### NatSpec 문서화

```solidity
/**
 * @title MyContract
 * @notice 사용자 대상 설명
 * @dev 개발자 대상 상세 설명
 */
contract MyContract {
    /**
     * @notice 함수 설명
     * @param value 파라미터 설명
     * @return 반환값 설명
     */
    function myFunction(uint256 value) public returns (uint256) {
        // ...
    }
}
```

## 테스트 작성

### 테스트 파일 구조

```
test/
├── unit/                   # 단위 테스트
│   ├── Kernel.t.sol
│   └── Paymaster.t.sol
├── integration/            # 통합 테스트
│   └── UserOperation.t.sol
└── invariant/              # 불변성 테스트
    └── EntryPoint.invariant.t.sol
```

### 테스트 작성 예시

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Kernel} from "../src/erc7579-smartaccount/Kernel.sol";

contract KernelTest is Test {
    Kernel public kernel;
    address public owner;

    function setUp() public {
        owner = makeAddr("owner");
        // 초기화
    }

    function test_Initialize() public {
        // Given
        // When
        // Then
    }

    function testFuzz_Transfer(uint256 amount) public {
        vm.assume(amount > 0 && amount < 1e18);
        // Fuzz 테스트
    }

    function testRevert_InvalidOwner() public {
        vm.expectRevert();
        // 실패 케이스 테스트
    }
}
```

### 테스트 실행

```bash
# 전체 테스트
forge test

# 상세 로그
forge test -vvv

# 특정 테스트
forge test --match-test test_Initialize

# 특정 컨트랙트
forge test --match-contract KernelTest

# Gas 리포트
forge test --gas-report

# 커버리지
forge coverage
```

## 배포 스크립트 작성

### 기본 구조

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper} from "./utils/DeploymentAddresses.sol";
import {MyContract} from "../src/MyContract.sol";

contract DeployMyContractScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        vm.startBroadcast();

        MyContract myContract = new MyContract();
        _setAddress("myContract", address(myContract));
        console.log("MyContract:", address(myContract));

        vm.stopBroadcast();

        _saveAddresses();
    }
}
```

### 배포 실행

```bash
# 로컬 배포
forge script script/DeployMyContract.s.sol:DeployMyContractScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

# 테스트넷 배포 (검증 포함)
forge script script/DeployMyContract.s.sol:DeployMyContractScript \
  --rpc-url $RPC_URL_SEPOLIA \
  --broadcast \
  --verify
```

## 디버깅

### Console 로그

```solidity
import {console} from "forge-std/console.sol";

function myFunction() public {
    console.log("Value:", someValue);
    console.logAddress(msg.sender);
    console.logBytes32(keccak256("data"));
}
```

### Trace

```bash
# 트랜잭션 트레이스
cast run <TX_HASH> --rpc-url http://127.0.0.1:8545

# 디버그 모드
forge test --debug test_MyFunction
```

### Anvil 디버깅

```bash
# 상세 로그와 함께 Anvil 시작
anvil --chain-id 31337 --hardfork prague -vvv

# 특정 블록 상태 확인
cast call <CONTRACT> "balanceOf(address)" <ADDRESS> \
  --rpc-url http://127.0.0.1:8545
```

## Gas 최적화

### Gas 리포트

```bash
forge test --gas-report
```

### 최적화 팁

1. **Storage 최적화**
   ```solidity
   // Bad
   uint256 a; // slot 0
   uint256 b; // slot 1
   uint128 c; // slot 2

   // Good
   uint256 a; // slot 0
   uint128 b; // slot 1
   uint128 c; // slot 1 (packed)
   ```

2. **Calldata 사용**
   ```solidity
   // Bad
   function process(bytes memory data) external {}

   // Good
   function process(bytes calldata data) external {}
   ```

3. **Custom Errors**
   ```solidity
   // Bad
   require(x > 0, "Must be positive");

   // Good
   error MustBePositive();
   if (x == 0) revert MustBePositive();
   ```

## Foundry 프로파일

### fast 프로파일 (개발용)

```bash
forge build --profile fast
forge test --profile fast
```

빠른 빌드를 위해 IR 비활성화, optimizer runs 감소.

### default 프로파일 (프로덕션)

```bash
forge build
```

최적화된 바이트코드 생성.

## CI/CD

### GitHub Actions 예시

```yaml
name: CI

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Build
        run: forge build

      - name: Test
        run: forge test -vvv

      - name: Gas Report
        run: forge test --gas-report
```

## 유용한 명령어

```bash
# 컨트랙트 크기 확인
forge build --sizes

# ABI 생성
forge inspect MyContract abi

# Storage 레이아웃
forge inspect MyContract storage

# 바이트코드 생성
forge inspect MyContract bytecode

# 포맷팅
forge fmt

# 린트
forge lint

# 문서 생성
forge doc
```

## 참고 자료

- [Foundry Book](https://book.getfoundry.sh/)
- [ERC-4337 Spec](https://eips.ethereum.org/EIPS/eip-4337)
- [ERC-7579 Spec](https://eips.ethereum.org/EIPS/eip-7579)
- [ERC-5564 Spec](https://eips.ethereum.org/EIPS/eip-5564)
- [ERC-6538 Spec](https://eips.ethereum.org/EIPS/eip-6538)
