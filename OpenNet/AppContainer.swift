//
//  AppContainer.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/12.
//

final class AppContainer {

    private let apiService: any MatchAPIServiceProtocol = MockAPIService()

    let repository: OddsRepository

    init() {
        repository = OddsRepository(apiService: apiService)
        // oddsStreamFactory 使用 Repository init 的預設值 OddsStreamService
    }

    // 每次呼叫回傳新 instance，repository 則共用同一個。
    func makeOddsListViewModel() -> OddsListViewModel {
        OddsListViewModel(repository: repository)
    }
}
