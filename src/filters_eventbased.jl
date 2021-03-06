"""
Event driven particle filters
"""
function ebpf(y, sys, par, δ)
    """
    Event-based bootstrap particle filter
    """

    # Extract parameters
    A = sys.A
    C = sys.C
    Q = sys.Q
    R = sys.R

    T = sys.T
    N = par.N

    nx = size(A, 1)
    ny = size(C, 1)

    X = zeros(N, nx, T)
    W = zeros(N, T)

    Z = zeros(ny, T)
    Γ = zeros(T)

    Neff = zeros(T)
    fail = zeros(T)
    res = zeros(T)

    X[:, :, 1] = rand(Normal(0, 1), N, nx)
    W[:, 1] = 1/N .* ones(N, 1)

    idx = collect(1:N)
    Xr = X[:, :, 1]
    Wr = W[:, 1]

    N_T = N / 2

    for k = 2:T

        # Run event kernel, SOD
        if norm(Z[:, k-1] - y[:, k]) >= δ
            Γ[k] = 1
            Z[:, k] = y[:, k]
        else
            Γ[k] = 0
            Z[:, k] = Z[:, k-1]
        end

        Neff[k] = 1./sum(W[:, k-1].^2)
        if Neff[k] < N_T
            # Resample using systematic resampling
            idx = collect(1:N)
            wc = cumsum(W[:, k-1])
            u = (([0:(N-1)] + rand()) / N)[1]
            c = 1
            for i = 1:N
                while wc[c] < u[i]
                    c = c + 1
                end
                idx[i] = c
            end

            Xr = X[idx, :, k-1]
            Wr = 1/N .* ones(N, 1)
            res[k] = 1
        else
            Xr = X[:, :, k-1]
            Wr = W[:, k-1]
        end


        # Propagate
        for i = 1:N
            X[i, :, k] = A*Xr[i, :] + rand(MvNormal(zeros(nx), Q))
        end

        # Weight
        if Γ[k] == 1
            for i = 1:N
                W[i, k] = log(Wr[i]) + log(pdf(MvNormal(C*X[i, :, k], R), y[:, k]))
            end
        else
            for i = 1:N
                # constrained bayesian state estimation
                D = Normal((C*X[i, :, k])[1], R[1])
                yh = C*X[i, :, k] 
                if norm(Z[:, k] -  yh) < δ
                    W[i, k] = log(Wr[i]) + log(pdf(D, yh[1]))
                else
                    W[i, k] = -Inf
                end

            end
        end

        if maximum(W[:, k]) > -Inf
            w_max = maximum(W[:, k])
            W_norm = sum(exp.(W[:, k] - w_max*ones(N, 1)))
            W[:, k] = exp.(W[:, k] - w_max*ones(N, 1)) / W_norm
        else
            println("Bad conditioned weights for EBPF! Resetting to uniform")
            W[:, k] = 1/N * ones(N, 1)
            fail[k] = 1
            Neff[k] = 0
        end


    end

    return X, W, Z, Γ, Neff, res, fail
end

function eapf(y, sys, par, δ)
    """
    Event-based auxiliary particle filter
    """

    # Extract parameters
    A = sys.A
    C = sys.C
    Q = sys.Q
    R = sys.R

    T = sys.T
    N = par.N

    # For approximating the uniform distribution
    # number of approximation points and their spacing
    M = 5 
    L = 2*δ / (M)
    Vn = L / 2

    nx = size(A, 1)
    ny = size(C, 1)

    X = zeros(N, nx, T)
    W = zeros(N, T)
    V = zeros(N, T)

    Z = zeros(ny, T)
    Γ = zeros(T)

    Neff = zeros(T)
    res = zeros(T)
    fail = zeros(T)

    X[:, :, 1] = rand(Normal(0, 1), N, nx)
    W[:, 1] = 1/N .* ones(N, 1)
    V[:, 1] = 1/N .* ones(N, 1)

    idx = collect(1:N)

    q_list = Array{Distribution}(N)
    q_aux_list = Array{Distribution}(N)

    Wr = W[:, 1]
    Xr = X[:, :, 1]
    Wr = W[:, 1]

    N_T = N/2
    yh = zeros(M)

    JP_m(x) = [A*x, C*A*x]
    JP_s(S) = [[Q] [Q*C'];
                [C*Q] [C*Q*C' + S]]
    for k = 2:T

        # Run event kernel, SOD
        if norm(Z[:, k-1] - y[:, k]) >= δ
            Γ[k] = 1
            Z[:, k] = y[:, k]
        else
            Γ[k] = 0
            Z[:, k] = Z[:, k-1]

            # Discretisize the uniform distribution, currently only supports
            # dim(y) = 1
            yh = vcat(linspace(Z[:, k]- δ, Z[:, k] + δ, M)...)
        end

        # Calculate auxiliary weights
        if Γ[k] == 1
            for i = 1:N
                μ = JP_m(X[i, :, k-1])
                Σ = JP_s(R)

                q_aux_list[i] = MvNormal(μ[2], Σ[2,2])
                V[i, k-1] = log(W[i, k-1]) + log(pdf(q_aux_list[i], Z[:,k]))
            end
        else
            for i = 1:par.N
                μ = JP_m(X[i, :, k-1])
                Σ = JP_s(R + Vn)

                q_aux_list[i] = MvNormal(μ[2], Σ[2,2])

                predLh = 0
                for j = 1:M
                    predLh += pdf(q_aux_list[i], yh[j, :])
                end
                predLh /= M

                V[i, k-1] = log(W[i, k-1]) + log(predLh)
            end
        end
        if maximum(V[:, k-1]) > -Inf
            V_max = maximum(V[:, k-1])
            V_norm = sum(exp.(V[:, k-1] - V_max*ones(N, 1)))
            V[:, k-1] = exp.(V[:, k-1] - V_max*ones(N, 1)) / V_norm
        else
            println("Bad conditioned weights for Auxiliary variable! Resetting to W(k-1)")
            V[:, k-1] = W[:, k-1]
            fail[k] = 1
        end

        Neff[k] = 1/sum(V[:, k-1].^2)
        if Neff[k] < N_T
            # Resample using systematic resampling
            idx = collect(1:N)
            wc = cumsum(V[:, k-1])
            u = (([0:(N-1)] + rand()) / N)[1]
            c = 1
            for i = 1:N
                while wc[c] < u[i]
                    c = c + 1
                end
                idx[i] = c
            end

            Xr = X[idx, :, k-1]
            Wr = 1/N * ones(N, 1)
            q_aux_list = q_aux_list[idx]
            res[k] = 1
        else
            Xr = X[:, :, k-1]
            Wr = W[:, k-1]
        end

        # Propagate
        if Γ[k] == 1
            for i = 1:N

                μ = JP_m(Xr[i, :])
                Σ = JP_s(R)

                S = fix_sym(Σ[1,1] - Σ[1, 2]*inv(Σ[2, 2])*Σ[1,2]')

                q_list[i] = MvNormal(μ[1] + Σ[1,2]*inv(Σ[2,2])*(Z[:,k] - μ[2]), S)
                X[i, :, k] = rand(q_list[i])
            end
        else
            for i = 1:par.N

                μ = JP_m(Xr[i, :])
                Σ = JP_s(R + Vn)

                wh = zeros(M)
                for j = 1:M
                    wh[j] = pdf(MvNormal(μ[2], Σ[2, 2]), yh[j, :])
                end

                if sum(wh) > 0
                    wh = wh ./ sum(wh)
                else
                    println("Bad conditioned weights for Mixture Gaussian; resetting to uniform")
                    wh = 1 / M * ones(M)
                end


                S = fix_sym(Σ[1,1] - Σ[1, 2]*inv(Σ[2, 2])*Σ[1,2]')
                μ_func(yh) = μ[1] + Σ[1,2]*inv(Σ[2,2])*(yh - μ[2])

                MD = MixtureModel(map(y -> MvNormal([μ_func(y)...], S), yh), wh)

                q_list[i] = MD
                X[i, :, k] = rand(q_list[i])
            end
        end

        # Weight
        if Γ[k] == 1
            for i = 1:par.N
                if res[k] == 1
                    W[i, k] = log(Wr[i]) + log(pdf(MvNormal(C*X[i, :, k], R), Z[:,k])) +
                                log(pdf(MvNormal(A*Xr[i, :], Q), X[i, :, k])) -
                                log(pdf(q_list[i], X[i, :, k])) -
                                log(pdf(q_aux_list[i], Z[:, k]))
                else
                    W[i, k] = log(Wr[i]) + log(pdf(MvNormal(C*X[i, :, k], R), Z[:,k])) +
                                log(pdf(MvNormal(A*Xr[i, :], Q), X[i, :, k])) -
                                log(pdf(q_list[i], X[i, :, k]))
                end
            end
        else
            for i = 1:par.N

                # Likelihood state constrained
                D = Normal((C*X[i, :, k])[1], R[1])
                yp = C*X[i, :, k]
                if norm(Z[:, k] - yp) < δ
                    py = pdf(D, yp[1])
                else
                    py = 0
                end

                # Propagation
                px = pdf(MvNormal(A*Xr[i, :], Q), X[i, :, k])

                # proposal distribution
                q = pdf(q_list[i], X[i, :, k])

                # Predictive likelihood
                pL = 0
                for j = 1:M
                    pL += pdf(q_aux_list[i], yh[j, :])
                end
                pL /= M

                if res[k] == 1
                    W[i, k] = log(Wr[i]) + log(py) + log(px) - log(pL) - log(q)
                else
                    W[i, k] = log(Wr[i]) + log(py) + log(px) - log(q)
                end

            end
        end


        if maximum(W[:, k]) > -Inf
            w_max = maximum(W[:, k])
            W_norm = sum(exp.(W[:, k] - w_max*ones(N, 1)))
            W[:, k] = exp.(W[:, k] - w_max*ones(N, 1)) / W_norm
        else
            println("Bad conditioned weights for EAPF! Resetting to uniform")
            W[:, k] = 1/par.N * ones(par.N, 1)
            fail[k] = 1
        end


    end

    return X, W, Z, Γ, Neff, res, fail
end

"""
Event-based state estimator
"""
function ebse(y, sys, δ)

    # Extract parameters
    A = sys.A
    C = sys.C
    Q = sys.Q
    R = sys.R

    T = sys.T

    # For approximating the uniform distribution
    # number of approximation points and their spacing
    M = 5 
    L = 2*δ / (M)
    Vn = L / 2

    nx = size(A, 1)
    ny = size(C, 1)

    xp = zeros(nx, T)
    Pp = zeros(nx, nx, T)
    yp = zeros(ny, T)
    Z = zeros(ny, T)
    Γ = zeros(T)

    x = zeros(nx, T)
    P = zeros(nx, nx, T)

    P[:,:,1] = eye(nx)

    for k = 2:T

        # Run event kernel, SOD
        if norm(Z[:, k-1] - y[:, k]) >= δ
            Γ[k] = 1
            Z[:, k] = y[:, k]
        else
            Γ[k] = 0
            Z[:, k] = Z[:, k-1]

            # Discretisize the uniform distribution, currently only supports
            # dim(y) = 1
            yh = vcat(linspace(Z[:, k]- δ, Z[:, k] + δ, M)...)
        end

        # Predict
        xp = A*x[:, k-1]
        Pp = A*P[:, :, k-1]*A' + Q

        # Update
        S = inv(inv(Pp) + C'*inv(R)*C)

        if Γ[k] == 1
            x[:, k] = S*(inv(Pp)*xp + C'*inv(R)*Z[:, k])
            P[:, :, k] = S
        else
            θ = zeros(2, M)
            w = zeros(1, M)
            for i = 1:M
                θ[:, i] = S*(inv(Pp)*xp + C'*inv(R)*yh[i])
                w[:, i] = pdf(MvNormal(C*xp, C*Pp*C' + R + Vn), yh[i, :])
            end
            w /= sum(w)

            for i = 1:M
                x[:, k] += w[:, i] .* θ[:, i]
            end

            for i = 1:M
                P[:, :, k] += w[:, i] .* (S + (x[:, k] - θ[:, i])*(x[:, k] - θ[:, i])')
            end
        end
    end

    return x, P, Z, Γ

end
